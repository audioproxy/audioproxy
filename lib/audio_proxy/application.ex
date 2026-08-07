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

    # Staging left behind by a write that was killed outright would otherwise
    # accumulate forever. Before the tree starts, nothing can be staging.
    case config.variant_store do
      {:file, root} -> AudioProxy.VariantStore.Local.sweep_staging(root)
      _other -> :ok
    end

    # S3's HTTP client gets a `:httpc` profile of its own, sized against
    # AP_MAX_CONCURRENCY — the default profile is shared with the rest of the
    # VM and allows two sessions per host, which would throttle concurrent
    # renders on the connection pool instead of on the semaphore meant to
    # govern them. Started unconditionally: it costs one idle process, and
    # making it conditional would mean a deployment that gains S3 config
    # without a restart finds no profile.
    AudioProxy.S3.HttpClient.setup!(config.max_concurrency)

    if config.allow_insecure do
      Logger.warning(
        "AP_ALLOW_INSECURE is enabled — /insecure/ URLs bypass signature verification; never enable in production"
      )
    end

    # Renders before the listener: a request that arrives on the first accepted
    # connection must find somewhere to start a subprocess. The coalescing
    # registry and its supervisor sit between them, because a coordinator
    # spawns a render in `init/1` and must therefore stop before the thing it
    # spawns into — which reverse-order shutdown gives for free. The tee
    # supervisor sits first for the same reason: coordinators spawn tees too,
    # and a coordinator stopping is what tells its tee to abort.
    #
    # The semaphore is ahead of both, for that reason read the other way round:
    # a coordinator releases its slot from `terminate/2`, so the thing it
    # releases into has to still be there when the last coordinator stops.
    children =
      [
        AudioProxy.Semaphore,
        # Behind the semaphore, because a scrape samples it. Ahead of the
        # listener for the reason `AudioProxy.Readiness` is: once `/metrics` is
        # served, the first accepted connection may be the scraper's.
        AudioProxy.Metrics,
        # Reads the semaphore's depth, so it starts behind it — and ahead of
        # the listener, because `/ready` must have somewhere to ask on the
        # first accepted connection.
        AudioProxy.Readiness,
        AudioProxy.VariantStore.Tee.supervisor(),
        AudioProxy.Ffmpeg.RenderSupervisor
      ] ++
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
