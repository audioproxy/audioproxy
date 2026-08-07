defmodule AudioProxy.Source.S3BackendTest.Unavailable do
  @moduledoc """
  A store that is up enough to answer and down enough to be useless.

  Every request draws a `503` carrying the XML body S3 sends when it is
  shedding load, so `ex_aws` reports `{:http, 503, _}` — the shape the seam
  must not fold into the blind 404. Injected here rather than provoked out of
  MinIO because a store cannot be asked to have an outage on cue.
  """

  @behaviour Plug

  @body """
  <?xml version="1.0" encoding="UTF-8"?>
  <Error><Code>SlowDown</Code><Message>Please reduce your request rate.</Message></Error>
  """

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(503, @body)
  end
end

defmodule AudioProxy.Source.S3BackendTest do
  @moduledoc """
  The `s3://` storage seam against a real store, and the flows that sit on it.

  `AudioProxy.Source.S3Test` pins the classification as a pure mapping, which
  is what makes it exhaustive over `t:AudioProxy.S3.error/0`. This is what
  keeps that mapping honest: a store decides which shape a missing object, a
  refused credential and an outage actually produce, and a stub deciding that
  for us would agree with whatever we assumed.

  It is also where the seam's claim is tested rather than asserted — that
  `/info` and the render path gained S3 sources with no change of their own.
  Both run here through the production chain up to the action, with
  `AudioProxy.FakeFfmpeg` at the end for the reason
  `AudioProxy.RenderEndpointTest` gives: the encoder is not what this slice
  changed.

  What that stand-in cannot show is a real ffmpeg opening a presigned URL and
  ranging it. `ffmpeg_input/1`'s URL is fetched here for real, so the URL is
  proven; the binary reading one end to end is the container smoke suite's
  job, where both a store and the shipped ffmpeg exist.

  Tagged `:minio` and excluded by default, failing rather than skipping when
  the store is missing — see `AudioProxy.S3Test`.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import Plug.Test

  alias AudioProxy.{ErrorJSON, S3, Signature}
  alias AudioProxy.Source.S3, as: SourceS3

  @moduletag :minio
  @moduletag timeout: 120_000

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  @bucket "audio-proxy-test"
  @body "RIFF-fake-wav-bytes"

  setup_all do
    endpoint = URI.parse(System.get_env("AP_TEST_MINIO_ENDPOINT", "http://minio:9000"))

    ensure_reachable!(endpoint)
    {:ok, endpoint: endpoint}
  end

  setup %{endpoint: endpoint} do
    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      presign_ttl: 900,
      max_src_bytes: 2_000_000_000,
      max_variant_bytes: 2_000_000_000,
      # Empty is "everything": the proxy's own credentials are the first gate,
      # and the allowlist is `AudioProxy.Source.AllowlistTest`'s subject.
      source_allowlist: [],
      s3: %{
        region: "us-east-1",
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        session_token: nil,
        endpoint: endpoint,
        # MinIO is reached by hostname and port, so `bucket.minio` would need
        # DNS nobody configured — same constraint as `AudioProxy.S3Test`.
        addressing: :path,
        ca_bundle: nil
      }
    })

    ensure_bucket!()
    reset_coordinators()
    reset_probes()

    key = unique_key("piece.wav")
    :ok = S3.put_stream(@bucket, key, [@body])

    {:ok, key: key}
  end

  describe "stat/1 against a real store" do
    test "reports the object's own size and ETag", %{key: key} do
      assert {:ok, stat} = SourceS3.stat({:s3, @bucket, key})
      assert {:ok, object} = S3.head(@bucket, key)

      assert stat.size == byte_size(@body)
      assert stat.etag == object.etag
      # The seam takes these two and nothing else: `size` answers 413 before a
      # subprocess starts, `etag` is what `/info`'s validator hashes.
      assert Map.keys(stat) |> Enum.sort() == [:etag, :size]
    end

    test "a missing object is the blind 404's reason" do
      assert SourceS3.stat({:s3, @bucket, unique_key("absent.wav")}) == {:error, :not_found}
    end

    test "a refused credential is byte-identical to a missing object", %{key: key} do
      missing = SourceS3.stat({:s3, @bucket, unique_key("absent.wav")})

      put_config(%{s3: %{AudioProxy.Config.get(:s3) | secret_access_key: "wrong-secret"}})

      # The object exists and the credential is refused; the client must not
      # be able to tell that from the object not being there.
      assert {:error, reason} = SourceS3.stat({:s3, @bucket, key})
      assert {:error, ^reason} = missing
      assert ErrorJSON.render(reason) == ErrorJSON.render(:not_found)
    end
  end

  describe "ffmpeg_input/1 against a real store" do
    test "returns a single argv element that fetches the object", %{key: key} do
      assert {:ok, url} = SourceS3.ffmpeg_input({:s3, @bucket, key})

      # One element, and one that works: what ffmpeg is handed is a URL it can
      # open on its own, so no source bytes cross the BEAM.
      assert is_binary(url)
      assert {200, @body} = fetch(url)
    end

    test "the URL is bounded by AP_PRESIGN_TTL", %{key: key} do
      put_config(%{presign_ttl: 120})

      assert {:ok, url} = SourceS3.ffmpeg_input({:s3, @bucket, key})
      assert URI.decode_query(URI.parse(url).query)["X-Amz-Expires"] == "120"
    end
  end

  describe "the render path gained S3 sources with no change of its own" do
    test "a signed render of an s3:// source streams the variant", %{key: key} do
      conn = render(key)

      assert conn.status == 200
      assert header(conn, "content-type") == "audio/mpeg"
      assert header(conn, "x-audio-proxy") == "MISS"
      assert conn.resp_body == "fake-audio-payload"
    end

    test "an object over AP_MAX_SRC_BYTES is a 413 and spawns nothing", %{key: key} do
      put_config(%{max_src_bytes: byte_size(@body) - 1})

      conn = render(key)

      assert conn.status == 413
      assert JSON.decode!(conn.resp_body)["error"] == "source_too_large"
    end

    test "a missing object is the blind 404" do
      conn = render(unique_key("absent.wav"))

      assert conn.status == 404

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "not_found",
               "message" => "Source not found"
             }
    end
  end

  describe "the info path gained S3 sources with no change of its own" do
    test "an s3:// source is described by the §4 contract", %{key: key} do
      conn = info(key)

      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/json"

      body = JSON.decode!(conn.resp_body)

      # The size is the HEAD's, which is the half of the seam `/info` reads.
      assert body["size"] == byte_size(@body)
      assert body["format"] == "wav"
    end

    test "an oversized object is still described", %{key: key} do
      # 413 is a render verdict: `/info` describes a source of any size, which
      # is a property of the action rather than of this backend, asserted here
      # because an S3 source is the first one big enough to make it matter.
      put_config(%{max_src_bytes: byte_size(@body) - 1})

      assert info(key).status == 200
    end

    test "an s3:// source carries a validator", %{key: key} do
      assert header(info(key), "etag") =~ ~r/^"[0-9a-f]+"$/
    end
  end

  describe "a store that is down is not a store that is empty" do
    setup do
      # An injected 5xx: everything MinIO would have answered, answered 503
      # instead. `ex_aws` reports it as `{:http, 503, _}`, which is the shape
      # the seam must not fold into the blind 404.
      store =
        start_supervised!(
          {Bandit,
           plug: AudioProxy.Source.S3BackendTest.Unavailable,
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0}
        )

      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(store)

      put_config(%{
        s3: %{
          AudioProxy.Config.get(:s3)
          | endpoint: URI.parse("http://127.0.0.1:#{port}")
        }
      })

      :ok
    end

    test "the seam reports an upstream failure, not a missing object", %{key: key} do
      assert SourceS3.stat({:s3, @bucket, key}) == {:error, :upstream_unavailable}
    end

    test "a render answers 502 with no-store", %{key: key} do
      conn = render(key)

      assert conn.status == 502
      assert header(conn, "cache-control") == "no-store"

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "upstream_unavailable",
               "message" => "Storage backend is unavailable"
             }
    end

    test "an info request answers 502 too", %{key: key} do
      assert info(key).status == 502
    end

    test "and it does not read as a missing object", %{key: key} do
      # The whole reason the row exists: a client that cannot tell an outage
      # from a deletion stops retrying a request that would have worked once
      # the store is back, and an edge cache holds that verdict for ten
      # seconds on its behalf.
      outage = render(key)

      refute outage.status == 404
      refute outage.resp_body == JSON.encode!(%{error: "not_found", message: "Source not found"})
      refute header(outage, "cache-control") == "max-age=10"
    end
  end

  describe "a store that cannot be reached at all" do
    setup do
      # Nothing is listening, so the failure is at the transport rather than in
      # a response — the other half of the 502 row, and the one an outage
      # actually looks like from a proxy's side.
      put_config(%{
        s3: %{AudioProxy.Config.get(:s3) | endpoint: URI.parse("http://127.0.0.1:1")}
      })

      :ok
    end

    test "a transport failure is an upstream failure, not a missing object", %{key: key} do
      assert SourceS3.stat({:s3, @bucket, key}) == {:error, :upstream_unavailable}
    end

    test "a render answers 502", %{key: key} do
      assert render(key).status == 502
    end
  end

  ## Driving the flows

  defp render(key), do: request("/f:mp3/plain/s3://#{@bucket}/#{key}")

  defp info(key), do: request("/info/plain/s3://#{@bucket}/#{key}")

  defp request(rest) do
    path = "/#{Signature.sign(rest, @key, @salt)}#{rest}"

    conn(:get, path) |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end

  defp header(conn, name) do
    case Plug.Conn.get_resp_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  ## Fixture

  defp unique_key(name), do: "source-backend/#{System.unique_integer([:positive])}/#{name}"

  defp ensure_bucket! do
    case @bucket |> ExAws.S3.put_bucket("us-east-1") |> ExAws.request(S3.config()) do
      {:ok, _response} ->
        :ok

      {:error, {:http_error, 409, %{body: body}}} ->
        unless body =~ "BucketAlreadyOwnedByYou" or body =~ "BucketAlreadyExists" do
          raise "could not create the #{@bucket} bucket: #{body}"
        end

        :ok

      other ->
        raise "could not create the #{@bucket} bucket: #{inspect(other)}"
    end
  end

  defp ensure_reachable!(endpoint) do
    url = URI.to_string(%{endpoint | path: "/minio/health/live"})

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [connect_timeout: 2_000, timeout: 5_000],
           []
         ) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        :ok

      other ->
        raise """
        MinIO is not reachable at #{URI.to_string(endpoint)} (#{inspect(other)}).

        These tests are tagged :minio and excluded by default; running them
        requires a store. See docs/development.md, or set
        AP_TEST_MINIO_ENDPOINT.
        """
    end
  end

  defp fetch(url) do
    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    {status, body}
  end
end
