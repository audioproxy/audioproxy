defmodule AudioProxy.LogHandlerTest do
  @moduledoc """
  What an operator actually sees: the request line's contents, its level, and
  the guarantee that no credential is ever in it.

  The request line is driven by executing `[:bandit, :request, :stop]` against
  a conn the real plug chain produced — the handler's inputs are the conn's
  assigns and Bandit's measurements, and both are reproduced exactly. That
  Bandit really emits that event, with those measurement keys and a conn in
  its metadata, is pinned separately over a socket by
  `AudioProxy.RequestLoggingIntegrationTest`; splitting it that way is what
  keeps the twenty assertions below off a listening port.

  The render lifecycle needs no such staging: those events come from
  `AudioProxy.Plugs.RenderAction` itself, so rendering through the stand-in
  encoder produces them for real.

  `async: false` throughout — the handler is attached process-globally at
  boot, `put_config/1` writes `:persistent_term`, and half of these tests move
  the primary Logger level.
  """

  use ExUnit.Case, async: false

  doctest AudioProxy.LogHandler

  import AudioProxy.ConfigHelper
  import ExUnit.CaptureLog
  import Plug.Test

  alias AudioProxy.Signature

  @moduletag tmp_dir: "log_handler"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @opts AudioProxy.Router.init([])
  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  # Anything with a `?` in it: the guarantee is that no query string survives,
  # not merely that this one parameter name does.
  @signature "X-Amz-Signature"

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")
    File.write!(Path.join(tmp_dir, "notaudio.txt"), "definitely not audio")
    File.write!(Path.join(tmp_dir, "presigned.wav"), "RIFF")

    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000
    })

    :ok
  end

  describe "the request line" do
    test "a successful render logs one info line with class, options, source, status and bytes" do
      log =
        capture_log(fn ->
          log_request(render(signed("/f:opus/br:96/plain/local://piece.wav")))
        end)

      assert [line] = request_lines(log)
      assert line =~ "[info]"
      assert line =~ "render 200"
      assert line =~ "opts=br:96/f:opus"
      assert line =~ "src=local://piece.wav"
      assert line =~ "18 bytes"
      assert line =~ ~r/in \d+\.\d+ms/
    end

    test "the line carries the request id, so a render's own lines correlate with it" do
      conn = render(signed("/f:mp3/plain/local://piece.wav"))
      [id] = Plug.Conn.get_resp_header(conn, "x-request-id")

      log = capture_log(fn -> log_request(conn) end)

      assert log =~ "request_id=#{id}"
      refute id == ""
    end

    # `:unsigned` is the 401 itself — a path whose first segment is not a
    # signature; the other two have to be signed to reach the plug that
    # rejects them.
    for {status, class, sign?, path} <- [
          {401, "invalid_signature", :unsigned, "/nosig/f:mp3/plain/local://piece.wav"},
          {404, "not_found", :signed, "/f:mp3/plain/local://nope.wav"},
          {422, "invalid_options", :signed, "/nope:1/plain/local://piece.wav"}
        ] do
      test "a #{status} is one calm info line naming the error class" do
        path =
          case unquote(sign?) do
            :signed -> signed(unquote(path))
            :unsigned -> unquote(path)
          end

        log = capture_log(fn -> log_request(get(path)) end)

        assert [line] = request_lines(log)
        assert line =~ "[info]"
        assert line =~ "render #{unquote(status)} #{unquote(class)}"
        refute log =~ "[warning]"
        refute log =~ "[error]"
      end
    end

    test "a render timeout is a warning naming the failure class" do
      log = capture_log(fn -> log_request(conn_with_error(:render_timeout)) end)

      assert [line] = request_lines(log)
      assert line =~ "[warning]"
      assert line =~ "504 render_timeout"
    end

    test "a 500 is a warning" do
      log = capture_log(fn -> log_request(conn_with_error(:render_failed)) end)

      assert [line] = request_lines(log)
      assert line =~ "[warning]"
      assert line =~ "500 render_failed"
    end

    test "an unrouted path logs as its own class, not as a render" do
      log = capture_log(fn -> log_request(get("/")) end)

      assert [line] = request_lines(log)
      assert line =~ "unknown 404 not_found"
    end
  end

  describe "health checks" do
    test "are silent at the default level" do
      log = at_level(:info, fn -> capture_log(fn -> log_request(get("/health")) end) end)

      assert request_lines(log) == []
    end

    test "appear at debug" do
      log = at_level(:debug, fn -> capture_log(fn -> log_request(get("/health")) end) end)

      assert [line] = request_lines(log)
      assert line =~ "[debug]"
      assert line =~ "health 200"
    end
  end

  describe "AP_LOG_LEVEL" do
    test "warning suppresses the happy path and keeps the failures" do
      log =
        at_level(:warning, fn ->
          capture_log(fn ->
            log_request(render(signed("/f:mp3/plain/local://piece.wav")))
            log_request(conn_with_error(:render_timeout))
          end)
        end)

      refute log =~ "render 200"
      assert log =~ "504 render_timeout"
    end
  end

  describe "the render lifecycle" do
    test "a failed render logs the class, exit status and diagnostic at warning" do
      log = capture_log(fn -> render(signed("/f:mp3/plain/local://notaudio.txt")) end)

      assert log =~ "[warning]"
      assert log =~ "render failed (undecodable, exit 1)"
      assert log =~ "mp3 local://notaudio.txt"
      assert log =~ "Invalid data found when processing input"
    end

    test "start and stop are debug, so the happy path stays one line at info" do
      log =
        at_level(:debug, fn ->
          capture_log(fn -> render(signed("/f:mp3/plain/local://piece.wav")) end)
        end)

      assert log =~ "render start mp3 local://piece.wav"
      assert log =~ "render ok mp3 local://piece.wav 18 bytes"
    end
  end

  describe "credentials never reach the log" do
    test "a diagnostic quoting a presigned URL is redacted, source identity intact" do
      log =
        at_level(:debug, fn ->
          capture_log(fn ->
            conn = render(signed("/f:mp3/plain/local://presigned.wav"))
            log_request(conn)
          end)
        end)

      # The stand-in encoder echoed a presigned URL onto stderr (see
      # fake_ffmpeg.sh); nothing of its query string may survive.
      refute log =~ @signature
      refute log =~ "X-Amz"
      refute log =~ "AWS4-HMAC-SHA256"
      refute log =~ "deadbeefcafe"

      # …while the line still says which source failed, and still says a URL
      # was in the diagnostic at all.
      assert log =~ "local://presigned.wav"
      assert log =~ "https://masters.s3.amazonaws.com/piece.wav?[redacted]"
    end

    test "the logged source is the canonical identity, never what ffmpeg was given" do
      log =
        at_level(:debug, fn ->
          capture_log(fn -> log_request(render(signed("/f:mp3/plain/local://piece.wav"))) end)
        end)

      assert log =~ "local://piece.wav"
      # ffmpeg was handed an absolute filesystem path — the future S3 backend
      # will hand it a presigned URL through the very same seam, and this is
      # the assertion that says the seam's output is not what gets logged.
      refute log =~ AudioProxy.Config.get(:local_root)
    end

    test "redact/1 strips query strings and bare credential parameters" do
      assert AudioProxy.LogHandler.redact("get https://b/k.wav?#{@signature}=abc now") ==
               "get https://b/k.wav?[redacted] now"

      assert AudioProxy.LogHandler.redact("#{@signature}=abc&Expires=99 trailing") ==
               "[redacted]&[redacted] trailing"

      assert AudioProxy.LogHandler.redact("nothing to hide here") == "nothing to hide here"
    end
  end

  ## Driving

  defp get(path), do: conn(:get, path) |> AudioProxy.Router.call(@opts)

  defp render(path), do: conn(:get, path) |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)

  defp signed(rest), do: "/#{Signature.sign(rest, @key, @salt)}#{rest}"

  # The two server-side statuses the plug chain cannot be talked into from a
  # URL: no source is missing enough to time out, and no request produces a
  # 500 without a broken host. Both are ordinary `ErrorJSON` halts otherwise.
  defp conn_with_error(reason) do
    conn(:get, "/whatever")
    |> Plug.Conn.assign(:endpoint_class, :render)
    |> AudioProxy.ErrorJSON.halt_with(reason)
  end

  # Bandit's `:stop` event, reproduced. `resp_body_bytes` is the byte count as
  # sent on the wire, `duration` is in native units.
  defp log_request(conn, bytes \\ nil) do
    bytes = bytes || IO.iodata_length(List.wrap(conn.resp_body))

    :telemetry.execute(
      [:bandit, :request, :stop],
      %{
        duration: System.convert_time_unit(3_200, :microsecond, :native),
        resp_body_bytes: bytes
      },
      %{conn: conn}
    )
  end

  # Only the request line, so a render's own debug lines cannot be mistaken
  # for it — every request line starts with its endpoint class.
  defp request_lines(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/\] (render|health|unknown) \d{3}/, &1))
  end

  defp at_level(level, fun) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: previous)
    end
  end
end
