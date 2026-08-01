defmodule AudioProxy.Application do
  @moduledoc """
  OTP application entry point.

  Reads and validates the `AP_*` environment (see `AudioProxy.Config`) before
  starting anything, so an invalid configuration aborts the boot rather than
  surfacing as a request-time failure.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    config = AudioProxy.Config.load!()

    if config.allow_insecure do
      Logger.warning(
        "AP_ALLOW_INSECURE is enabled — /insecure/ URLs bypass signature verification; never enable in production"
      )
    end

    # Renders before the listener: a request that arrives on the first accepted
    # connection must find somewhere to start a subprocess.
    children = [AudioProxy.Ffmpeg.RenderSupervisor] ++ listener(config)

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
