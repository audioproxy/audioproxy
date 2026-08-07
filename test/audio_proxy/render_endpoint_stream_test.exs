defmodule AudioProxy.RenderEndpointStreamTest do
  @moduledoc """
  The streaming lifecycle over a real socket: the parts of §5 that only exist
  once an adapter and a TCP connection are involved.

  `Plug.Test` can show the response head and the bytes
  (`AudioProxy.RenderEndpointTest` does), but not the three things below. A
  client cannot vanish mid-stream when there is no socket to close. A chunked
  response cannot be *torn down* rather than completed. And the wire framing —
  a terminating `0\\r\\n\\r\\n`, or its absence — is invisible from the conn. So
  this test binds Bandit on an ephemeral port and speaks HTTP/1.1 down a raw
  `:gen_tcp` socket.

  The renders are `AudioProxy.FakeFfmpeg`, not ffmpeg: a hang, a dribble and a
  failure-after-first-byte are things this has to produce on demand, and the
  real encoder produces none of them reliably. The full-stack run with real
  ffmpeg is `AudioProxy.RenderEndpointFfmpegTest`.

  Tagged `:integration`: excluded from the default `mix test` run (the suite
  otherwise binds no socket), included in CI via `mix test --include
  integration`.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.ProbeCoalesceHelper

  alias AudioProxy.{RawHttp, Signature}

  @moduletag :integration
  @moduletag tmp_dir: "render_stream"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @payload "fake-audio-payload"

  # Generous: every wait below is on something that should take milliseconds,
  # and a deadline this size only ever costs time when the test is failing.
  @deadline 5_000

  setup %{tmp_dir: tmp_dir} do
    for name <- ~w(quick.wav hang.wav dribble.wav midfail.wav failfast.wav) do
      File.write!(Path.join(tmp_dir, name), "RIFF")
    end

    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000,
      max_variant_bytes: 2_000_000_000,
      # One second, so the pre-stream timeout is a test and not a coffee break.
      render_timeout: 1
    })

    reset_probes()

    bandit =
      start_supervised!(
        {Bandit, plug: AudioProxy.FakeFfmpeg.Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    {:ok, port: port, bandit: bandit}
  end

  describe "a completed render" do
    test "is a chunked 200 that ends with the terminating chunk", %{port: port} do
      response = "/f:mp3/plain/local://quick.wav" |> request(port) |> RawHttp.read(@deadline)

      assert response.head =~ "http/1.1 200 ok"
      assert response.head =~ "transfer-encoding: chunked"
      assert RawHttp.dechunk(response.body) == @payload
      assert RawHttp.complete?(response.body)
    end
  end

  describe "client disconnect" do
    test "kills the render that had no other consumer", %{port: port, tmp_dir: tmp_dir} do
      input = Path.join(tmp_dir, "dribble.wav")
      socket = request("/f:mp3/plain/local://dribble.wav", port)

      # Wait for bytes, so the render is genuinely under way and the pid below
      # is the one this request spawned.
      assert {:ok, _first} = :gen_tcp.recv(socket, 0, @deadline)
      assert [os_pid] = subprocesses(input)

      :ok = :gen_tcp.close(socket)

      assert gone_within?(os_pid, @deadline),
             "the render outlived the only client that wanted it"
    end
  end

  describe "failure before the first byte" do
    test "a render that produces nothing within AP_RENDER_TIMEOUT is a 504", %{port: port} do
      response = "/f:mp3/plain/local://hang.wav" |> request(port) |> RawHttp.read(@deadline)

      assert response.head =~ "http/1.1 504"
      assert JSON.decode!(response.body)["error"] == "render_timeout"
    end

    test "a failure no classifier recognises is a 500, not a plausible 4xx", %{port: port} do
      response = "/f:mp3/plain/local://failfast.wav" |> request(port) |> RawHttp.read(@deadline)

      assert response.head =~ "http/1.1 500"
      assert JSON.decode!(response.body)["error"] == "render_failed"
    end

    test "the timed-out render leaves no subprocess behind", %{port: port, tmp_dir: tmp_dir} do
      input = Path.join(tmp_dir, "hang.wav")
      response = "/f:mp3/plain/local://hang.wav" |> request(port) |> RawHttp.read(@deadline)

      assert response.head =~ "http/1.1 504"
      assert [] == subprocesses(input)
    end
  end

  describe "failure after the first byte" do
    test "the chunked stream is torn down, not completed", %{port: port} do
      response = "/f:mp3/plain/local://midfail.wav" |> request(port) |> RawHttp.read(@deadline)

      # The status line went out before anything was known to be wrong, which
      # is exactly why §5 has nothing better than an abnormal close here.
      assert response.head =~ "http/1.1 200 ok"
      assert RawHttp.dechunk(response.body) =~ @payload

      refute RawHttp.complete?(response.body),
             "a failed render completed its stream, so the client believes it got the whole file"
    end

    test "a retention breach is a torn-down stream, never a 413", %{port: port} do
      # `AP_MAX_VARIANT_BYTES` cannot be a status code and this is why: the
      # dribbler's first chunk commits the response to `200` before the second
      # crosses the ceiling. 413 belongs to the source ceiling, which is spent
      # before a render starts; here the honest outcome is an abnormal close.
      put_config(%{max_variant_bytes: byte_size(@payload) + 1})

      response = "/f:mp3/plain/local://dribble.wav" |> request(port) |> RawHttp.read(@deadline)

      # The status line is the whole "never a 413" claim: it is already `200`
      # and spent. (Not `refute head =~ "413"` — an ETag is a hex digest and
      # one of them will eventually contain those three characters.)
      assert response.head =~ "http/1.1 200 ok"
      assert RawHttp.dechunk(response.body) =~ @payload

      refute RawHttp.complete?(response.body),
             "a render killed at the retention bound completed its stream"
    end
  end

  describe "keep-alive" do
    test "a cancelled render leaves nothing in the connection's mailbox", %{
      port: port,
      bandit: bandit
    } do
      # Bandit reuses this connection's process for the next request, so
      # anything the previous request left in that mailbox stays there: nothing
      # would ever match it again (the next request pins a different render
      # pid), and every selective receive in the streaming loop would scan past
      # it for the life of the connection.
      #
      # Today this passes with or without `cancel_and_drain/1`, and the reason
      # is worth writing down. A 504 normally arrives as the *render's* own
      # timer firing and sending `%{class: :timeout}`, which the loop consumes —
      # no cancellation, nothing left over. The action's own deadline is a
      # second wider (see the module's "backstop" note), so the path that
      # cancels, and therefore the path that can strand a `%{class: :cancelled}`
      # here, only runs when the backstop beats the render's timer. This pins
      # the invariant rather than the fix: it is what fails if a future change
      # starts cancelling on the ordinary timeout path.
      socket = RawHttp.get(signed("/f:mp3/plain/local://hang.wav"), port, close: false)

      timed_out = RawHttp.read_one(socket, @deadline)
      assert timed_out.head =~ "http/1.1 504"

      # Asserted on the process itself: the next request succeeding proves
      # nothing here, because a stale message is inert rather than harmful.
      #
      # `{:plug_conn, :sent}` is exempted: it is Plug's own bookkeeping, sent
      # by the adapter to the connection process itself, and Bandit discards
      # it in a `handle_info` clause of its own — which only runs once the
      # handler returns to its GenServer loop, a moment this assertion can
      # outrun (and on CI regularly did). It is Bandit's to consume; what
      # must not be here is anything of the *render's*.
      assert {:ok, [connection]} = ThousandIsland.connection_pids(bandit)
      {:messages, messages} = Process.info(connection, :messages)
      assert Enum.reject(messages, &match?({:plug_conn, :sent}, &1)) == []

      # And the connection still works afterwards.
      :ok = RawHttp.send_get(socket, signed("/f:mp3/plain/local://quick.wav"))
      second = RawHttp.read(socket, @deadline)

      assert second.head =~ "http/1.1 200 ok"
      assert RawHttp.dechunk(second.body) == @payload
      assert RawHttp.complete?(second.body)
    end
  end

  defp signed(rest), do: "/#{Signature.sign(rest, @key, @salt)}#{rest}"

  defp request(rest, port) do
    RawHttp.get(signed(rest), port)
  end

  ## Subprocess probing

  # Every stand-in render for `input` that the OS still knows about. Matching
  # on the script *and* the input path keeps another test's render out of the
  # answer.
  defp subprocesses(input) do
    {output, 0} = System.cmd("ps", ["-Ao", "pid=,args="], stderr_to_stdout: true)

    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&(String.contains?(&1, "fake_ffmpeg.sh") and String.contains?(&1, input)))
    |> Enum.map(fn line ->
      line |> String.trim_leading() |> String.split(" ", parts: 2) |> hd() |> String.to_integer()
    end)
  end

  defp gone_within?(_os_pid, remaining) when remaining <= 0, do: false

  defp gone_within?(os_pid, remaining) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(25)
        gone_within?(os_pid, remaining - 25)

      {_, _nonzero} ->
        true
    end
  end
end
