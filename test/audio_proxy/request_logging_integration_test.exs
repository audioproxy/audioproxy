defmodule AudioProxy.RequestLoggingIntegrationTest do
  @moduledoc """
  The one thing `AudioProxy.LogHandlerTest` cannot check for itself: that
  Bandit really emits `[:bandit, :request, :stop]`, once per request, with the
  conn in its metadata and the measurement keys the handler reads.

  Everything else about the log line is a pure function of those inputs and is
  tested without a socket. This test exists so that a Bandit upgrade which
  renamed `resp_body_bytes` — or stopped putting the conn in the metadata —
  fails here rather than by silently logging `0 bytes` in production.

  Tagged `:integration`: it binds a real listener, so it is excluded from the
  default run and included by CI via `mix test --include integration`.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest
  import ExUnit.CaptureLog

  alias AudioProxy.RawHttp

  @moduletag :integration
  @moduletag tmp_dir: "request_logging_integration"

  @handler_id {__MODULE__, :probe}

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")

    put_config(base_config(local_root: tmp_dir))

    bandit =
      start_supervised!(
        {Bandit, plug: AudioProxy.FakeFfmpeg.Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    {:ok, port: port}
  end

  @doc false
  def forward(event, measurements, metadata, pid) do
    send(pid, {:bandit_event, event, measurements, metadata})
  end

  test "the stop event carries the conn and the measurements the handler reads", %{port: port} do
    :ok =
      :telemetry.attach(
        @handler_id,
        [:bandit, :request, :stop],
        &__MODULE__.forward/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(@handler_id) end)

    request(signed("/f:mp3/plain/local://piece.wav"), port)

    assert_receive {:bandit_event, [:bandit, :request, :stop], measurements, metadata}, 5_000

    assert %Plug.Conn{} = conn = metadata.conn
    assert conn.status == 200
    assert conn.assigns.endpoint_class == :render
    assert conn.assigns.source == {:local, "piece.wav"}

    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert measurements.resp_body_bytes == 18

    # Exactly one per request: the whole reason for preferring this event to
    # `Plug.Logger`, which would log twice.
    refute_receive {:bandit_event, [:bandit, :request, :stop], _, _}, 200
  end

  test "the attached handler logs one line over a real socket", %{port: port} do
    log = capture_log(fn -> request(signed("/f:mp3/plain/local://piece.wav"), port) end)

    assert log =~ "render 200"
    assert log =~ "src=local://piece.wav"
    assert log =~ "18 bytes"
  end

  test "the request id in the log is the one the client got back", %{port: port} do
    path = signed("/f:mp3/plain/local://piece.wav")

    {head, log} = with_log(fn -> request(path, port) end)

    # `RawHttp.read/2` downcases the whole head, value included, so the
    # comparison has to be case-insensitive — the id itself is mixed case.
    assert [_, id] = Regex.run(~r/x-request-id: (\S+)/, head)
    assert String.downcase(log) =~ "request_id=#{id}"
  end

  # Returns the response head, and only returns once the socket has closed —
  # so the `:stop` event has certainly fired by the time a test asserts on it.
  defp request(path, port) do
    path
    |> RawHttp.get(port)
    |> RawHttp.read()
    |> Map.fetch!(:head)
  end
end
