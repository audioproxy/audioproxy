defmodule AudioProxy.Plugs.VerifySignatureIntegrationTest do
  @moduledoc """
  Socket-level verification that the *production* adapter (Bandit) hands the
  plug the raw, still-percent-encoded request path. `Plug.Test` sets
  `request_path` from whatever string the test passes, so the unit tests
  cannot catch an adapter that decodes `%20`/`%2F` before the signature is
  checked — this test binds a real listener and can.

  Coverage is HTTP/1.1 only: Bandit's HTTP/2 path builds `request_path` from
  the `:path` pseudo-header through separate code. The h2 case is deferred to
  the `add-docker-release` smoke suite (a real curl with
  `--http2-prior-knowledge`), since a raw h2 client here would be
  disproportionate.

  Tagged `:integration`: excluded from the default `mix test` run (the suite
  otherwise binds no socket), included in CI via `mix test --include
  integration`.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest

  alias AudioProxy.Signature

  @moduletag :integration

  defmodule TestPlug do
    @moduledoc false

    import Plug.Conn

    alias AudioProxy.Plugs.VerifySignature

    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      conn = VerifySignature.call(conn, opts)

      if conn.halted do
        conn
      else
        # Echo the verified rest-of-path and the adapter's path_info, so tests
        # can assert byte-identity with what was signed and pin how the
        # adapter segments the raw path.
        send_resp(conn, 200, conn.assigns[:rest_of_path] <> "\n" <> inspect(conn.path_info))
      end
    end
  end

  setup do
    put_config(%{key: key(), salt: salt(), allow_insecure: false})

    bandit =
      start_supervised!({Bandit, plug: TestPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    {:ok, port: port}
  end

  test "a signed URL with percent-escapes verifies and echoes the raw signed bytes", %{port: port} do
    rest = "/f:mp3/plain/s3://bucket/a%20track%2Ffinal.wav"
    sig = Signature.sign(rest, key(), salt())

    assert {200, body} = get("/#{sig}#{rest}", port)

    # path_info is pinned as documentation: the adapter does NOT decode
    # escapes, and it drops the empty segment inside "s3://". The signature
    # itself is just its first segment. Downstream must never parse
    # path_info (see the plug moduledoc) — the signed bytes are line one.
    assert body ==
             rest <>
               "\n" <>
               ~s(["#{sig}", "f:mp3", "plain", "s3:", "bucket", "a%20track%2Ffinal.wav"])
  end

  test "a plain signed URL verifies", %{port: port} do
    rest = "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav"

    assert {200, body} = get("/#{Signature.sign(rest, key(), salt())}#{rest}", port)
    assert String.starts_with?(body, rest)
  end

  test "an unsigned request is rejected", %{port: port} do
    assert {401, _body} = get("/nosig/f:opus/br:96/plain/s3://b/k.wav", port)
  end

  test "a tampered escape sequence is rejected", %{port: port} do
    rest = "/f:mp3/plain/s3://bucket/a%20track.wav"
    sig = Signature.sign(rest, key(), salt())

    assert {401, _body} = get("/#{sig}/f:mp3/plain/s3://bucket/a%21track.wav", port)
  end

  # Raw TCP client: the request-target goes on the wire byte-for-byte, so no
  # HTTP client library can normalize %20/%2F before Bandit sees them — the
  # exact behavior under test.
  defp get(path, port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      )

    response = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _headers] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    {String.to_integer(status), body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        recv_all(socket, acc <> data)

      {:error, :closed} ->
        acc

      {:error, :timeout} ->
        raise "timed out waiting for response (got #{byte_size(acc)} bytes so far)"
    end
  end
end
