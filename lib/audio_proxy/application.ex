defmodule AudioProxy.Application do
  @moduledoc """
  OTP application entry point.

  Reads and validates the `AP_*` environment (see `AudioProxy.Config`) before
  starting anything, so an invalid configuration aborts the boot rather than
  surfacing as a request-time failure.

  The log is set up in the same breath, and before the first line is emitted:
  `AP_LOG_LEVEL` is applied to the primary logger, and
  `AudioProxy.LogHandler` attaches to the telemetry the router and the render
  path produce. Neither is a process, so neither is in the supervision tree —
  a telemetry handler runs in whichever process emits the event.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    config = AudioProxy.Config.load!()

    Logger.configure(level: config.log_level)
    AudioProxy.LogHandler.attach()

    if config.allow_insecure do
      Logger.warning(
        "AP_ALLOW_INSECURE is enabled — /insecure/ URLs bypass signature verification; never enable in production"
      )
    end

    # Renders before the listener: a request that arrives on the first accepted
    # connection must find somewhere to start a subprocess. The coalescing
    # registry and its supervisor sit between them, because a coordinator
    # spawns a render in `init/1` and must therefore stop before the thing it
    # spawns into — which reverse-order shutdown gives for free.
    children =
      [AudioProxy.Ffmpeg.RenderSupervisor] ++
        AudioProxy.RenderCoordinator.children() ++ listener(config)

    Logger.info("audio_proxy #{vsn()} starting (serve_mode: #{config.serve_mode})")

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioProxy.Supervisor)
  end

  # The test suite drives the router through Plug.Test, so it binds no socket.
  defp listener(config) do
    if Application.get_env(:audio_proxy, :start_listener, true) do
      Logger.info("listening on http://0.0.0.0:#{config.port}")
      [{Bandit, plug: AudioProxy.Router, scheme: :http, port: config.port}]
    else
      []
    end
  end

  defp vsn, do: :audio_proxy |> Application.spec(:vsn) |> to_string()
end
