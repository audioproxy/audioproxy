defmodule AudioProxy.Telemetry do
  @moduledoc """
  The render lifecycle as `:telemetry` events — the one instrumentation point
  every consumer reads.

  `AudioProxy.LogHandler` is the first consumer and `AudioProxy.Metrics` the
  second, attached to the same events without touching the render path. That
  is the whole reason the render action emits events rather than calling
  `Logger` directly: instrument once, consume twice.

  ## Events

  Emitted around one render, always start-then-(stop | exception):

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:audio_proxy, :render, :start]` | `system_time` | `format`, `source`, `cache_status` |
  | `[:audio_proxy, :render, :stop]` | `duration` (native), `bytes` | `format`, `source`, `cache_status`, `outcome` |
  | `[:audio_proxy, :render, :exception]` | `duration` (native), `bytes` | `format`, `source`, `cache_status`, `class`, `exit_status`, `detail` |

  Two events stand apart from the render lifecycle:

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:audio_proxy, :cache, :lookup]` | `system_time` | `status`, `format` |
  | `[:audio_proxy, :variant_store, :write_failure]` | `system_time` | `key`, `reason` |

  The lookup event fires once per request that **delivers** a variant under one
  of §5's three `X-Audio-Proxy` values, and `status` is that value: `:hit`,
  `:miss` or `:coalesced`. Two consequences follow from tying it to delivery
  rather than to the store read behind it. A request that delivers nothing — a
  429, a 404, a 304 — emits nothing, so `hit / (hit + miss + coalesced)` is a
  ratio over variants actually served rather than over a denominator nobody
  can name. And a `:coalesced` request is not counted as a store miss even
  though its store lookup missed: it did not render either, and folding it
  into `:miss` would hide the number this proxy exists to move.

  **A HEAD is the one request that reports a verdict without being counted**,
  and the exemption is deliberate rather than incidental. Since
  `fix-head-response-headers` a HEAD carries `X-Audio-Proxy` in both shapes, so
  "commits to a header" stopped being the same question as "delivered
  something" — this is written against the second. The asymmetry is what makes
  it matter: only the hit side touches the store, so counting the header would
  add probe traffic to the numerator while the miss side, which never reaches
  the render path that emits, stayed out of the denominator. A player polling
  HEAD to decide whether playback will be instant — the reason the header is on
  a HEAD at all — would drive the ratio to 100% by asking. `AudioProxy.VariantCache`
  is where that split lives.

  It overlaps the render events' `cache_status` on purpose. That field
  describes a render, and there is no render behind a `:hit` — the request
  that was served one never reached `render_start/1`. One event covering all
  three is what makes the ratio a single subtraction instead of a join across
  two event families.

  The write-failure event is emitted by the write-back tee when storing a
  completed render fails — a failure no client sees (their bytes come from
  the coordinator, not the store), which is exactly why it must be
  instrumented: nothing else says the cache has silently stopped filling.

  `outcome` is `:ok` for a render the client received whole and `:cancelled`
  for one abandoned because the client went away. `class` is the failure
  classification (`:timeout`, `:not_found`, `:undecodable`, `:render_failed`,
  …); `exit_status` is ffmpeg's exit code where there is one and `nil`
  otherwise; `detail` is the diagnostic tail — an ffmpeg stderr excerpt or an
  inspected exit reason.

  ## `cache_status` is what makes a duration readable

  `:miss` means this request ran the encoder; `:coalesced` means it attached to
  a render another request had already started. Without it a span is genuinely
  misleading rather than merely incomplete: a request that joins a nearly
  finished render and drains its backlog reports megabytes in single-digit
  milliseconds, which reads as an impossibly fast ffmpeg. It is also the
  numerator a coalescing ratio needs, which is a headline number for a proxy
  whose whole point is not rendering twice — though the ratio itself is built
  from the cache lookup event above, which is the one that also sees a HIT.

  ## `source` is the canonical identity, never the ffmpeg input

  Metadata carries `AudioProxy.Source.canonical/1`'s output — `local://…`,
  later `s3://…` — and never `AudioProxy.Source.ffmpeg_input/1`'s, which for
  a remote source is a presigned URL carrying a live `X-Amz-Signature`. A
  handler that logged it would write a fetchable secret into log storage. The
  guarantee is structural: the input is not in the metadata, so no consumer
  can reach it. `detail` is the one field that carries text this module did
  not build, which is why `AudioProxy.LogHandler` redacts it.

  ## The span is data, not a process

  `render_start/1` returns a plain map that the render action threads through
  its receive loop and hands back to `render_stop/2` or `render_exception/2`.
  `:telemetry.span/3` would be the usual tool, but it wraps a function call,
  and the action's lifetime is a message loop with half a dozen exit points —
  there is no function to wrap.
  """

  @render [:audio_proxy, :render]
  @cache_lookup [:audio_proxy, :cache, :lookup]
  @store_write_failure [:audio_proxy, :variant_store, :write_failure]

  @typedoc """
  §5's three `X-Audio-Proxy` values, as the cache lookup event reports them.

  A render only ever sees the last two — `:hit` belongs to the request that
  never started one.
  """
  @type cache_status :: :hit | :miss | :coalesced

  @typedoc """
  What every render event describes: the variant, its source, and whether this
  request rendered it or attached to a render already running.
  """
  @type meta :: %{
          format: atom(),
          source: String.t(),
          cache_status: :miss | :coalesced
        }

  @typedoc """
  An in-flight render, threaded through the action's loop.

  Opaque in practice: build it with `render_start/1`, grow it with `count/2`,
  end it with `render_stop/2` or `render_exception/2`.
  """
  @type span :: %{meta: meta(), started_at: integer(), bytes: non_neg_integer()}

  @typedoc """
  How a render failed, as the render action knows it.

  `:class` is required; the rest is whatever the failure carries — the
  pipeline's `%{class:, exit_status:, stderr:}` is accepted as-is, and the
  action's own failures (a dead render, a blown deadline) pass `:detail`.
  """
  @type failure :: %{
          required(:class) => atom(),
          optional(:exit_status) => integer() | nil,
          optional(:stderr) => String.t(),
          optional(:detail) => String.t()
        }

  @doc "Every render event, for a consumer attaching to all of them."
  @spec render_events() :: [:telemetry.event_name()]
  def render_events, do: Enum.map([:start, :stop, :exception], &(@render ++ [&1]))

  @doc """
  Emits `[:audio_proxy, :render, :start]` and opens the span.
  """
  @spec render_start(meta()) :: span()
  def render_start(meta) do
    :telemetry.execute(@render ++ [:start], %{system_time: System.system_time()}, meta)

    %{meta: meta, started_at: System.monotonic_time(), bytes: 0}
  end

  @doc "Adds `bytes` delivered to the span."
  @spec count(span(), non_neg_integer()) :: span()
  def count(span, bytes), do: %{span | bytes: span.bytes + bytes}

  @doc """
  Emits `[:audio_proxy, :render, :stop]`, closing the span.
  """
  @spec render_stop(span(), :ok | :cancelled) :: :ok
  def render_stop(span, outcome) do
    :telemetry.execute(
      @render ++ [:stop],
      %{duration: duration(span), bytes: span.bytes},
      Map.put(span.meta, :outcome, outcome)
    )
  end

  @doc """
  Emits `[:audio_proxy, :render, :exception]`, closing the span.
  """
  @spec render_exception(span(), failure()) :: :ok
  def render_exception(span, failure) do
    metadata =
      Map.merge(span.meta, %{
        class: failure.class,
        exit_status: Map.get(failure, :exit_status),
        detail: Map.get(failure, :detail) || Map.get(failure, :stderr)
      })

    :telemetry.execute(
      @render ++ [:exception],
      %{duration: duration(span), bytes: span.bytes},
      metadata
    )
  end

  @doc "The cache lookup event's name, for consumers attaching to it."
  @spec cache_lookup_event() :: :telemetry.event_name()
  def cache_lookup_event, do: @cache_lookup

  @doc """
  Emits `[:audio_proxy, :cache, :lookup]`.

  Called once by whichever module commits to the answer: `AudioProxy.VariantCache`
  for a `:hit`, `AudioProxy.Plugs.RenderAction` for a `:miss` or a `:coalesced`.
  """
  @spec cache_lookup(%{status: cache_status(), format: atom()}) :: :ok
  def cache_lookup(meta) do
    :telemetry.execute(@cache_lookup, %{system_time: System.system_time()}, meta)
  end

  @doc "The write-back failure event's name, for consumers attaching to it."
  @spec store_write_failure_event() :: :telemetry.event_name()
  def store_write_failure_event, do: @store_write_failure

  @doc """
  Emits `[:audio_proxy, :variant_store, :write_failure]`.

  `reason` is whatever `AudioProxy.VariantStore.put_stream/3` reported — a
  posix atom, an exception — and is inspected, never raised, by consumers.
  """
  @spec store_write_failure(%{key: String.t(), reason: term()}) :: :ok
  def store_write_failure(meta) do
    :telemetry.execute(@store_write_failure, %{system_time: System.system_time()}, meta)
  end

  defp duration(span), do: System.monotonic_time() - span.started_at
end
