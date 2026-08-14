defmodule AudioProxy.Metrics do
  @moduledoc """
  The four operator signals, aggregated from telemetry and exposed to a
  scraper: saturation, latency, cache efficiency, errors.

  A GenServer owning one ETS table, plus a `:telemetry` handler that writes to
  it. The process is not in the write path — a handler runs in whichever
  process emitted the event and updates the table directly — so instrumenting
  a render costs an `:ets.update_counter/4` and no message. What the process is
  for is ownership: the table lives and dies with it, and `terminate/2` detaches
  the handler so nothing is left writing into a table that has gone.

  ## Why this and not `prom_ex`

  The dependency policy, and the same argument `add-s3-client` reached the
  opposite conclusion on. There the volume was decisive — ~2000 lines of
  signing against a contract AWS controls. Here the metric set is a dozen
  fixed series and the exposition format has been stable since 2014, so the
  whole of it is `AudioProxy.Metrics.Exposition` and the table below. A
  Prometheus library would bring a Phoenix-oriented dependency tree to save
  code this project can read in one sitting.

  ## Counted, and sampled

  Two kinds of metric, and the split is not cosmetic.

  **Counters and the histogram are event-driven** and accumulate in ETS. They
  are monotonic, so a concurrent update is `:ets.update_counter/4` and exact,
  and nothing is lost by reading them late.

  **Gauges are sampled at scrape time**, from `AudioProxy.Semaphore.stats/2`
  and the coalescing registry, not from events. A gauge maintained by events
  would need an increment and a decrement to balance for the life of the VM,
  and one abnormal exit — a Bandit connection process killed outright with a
  render attached — leaves it permanently wrong with nothing to correct it.
  Asking the semaphore what it holds cannot drift, because the semaphore *is*
  the answer. The cost is a `GenServer.call` per scrape, bounded by
  `@sample_timeout`; a semaphore that cannot answer within it omits its four
  gauges from that scrape rather than delaying it, which a scraper reads as a
  gap and an operator reads as the semaphore being the problem.

  ## What is exported

  | Metric | Type | Labels | Source |
  |---|---|---|---|
  | `audio_proxy_renders_total` | counter | `format`, `outcome` | render stop / exception |
  | `audio_proxy_render_duration_seconds` | histogram | `format`, `outcome` | render stop / exception |
  | `audio_proxy_renders_running` | gauge | — | coalescing registry |
  | `audio_proxy_render_slots_held` | gauge | — | semaphore |
  | `audio_proxy_render_slots_capacity` | gauge | — | semaphore |
  | `audio_proxy_render_queue_depth` | gauge | — | semaphore |
  | `audio_proxy_render_queue_capacity` | gauge | — | semaphore |
  | `audio_proxy_render_queue_rejections_total` | counter | — | semaphore `:rejected` |
  | `audio_proxy_cache_lookups_total` | counter | `format`, `outcome` | cache lookup |
  | `audio_proxy_variant_store_write_failures_total` | counter | — | write-back tee |
  | `audio_proxy_http_requests_total` | counter | `endpoint`, `status` | Bandit request stop |

  `outcome` on a render is `success` for one the client received whole,
  `cancelled` for one abandoned because the client went away, and otherwise
  the failure class (`timeout`, `undecodable`, `not_found`, …). `outcome` on a
  cache lookup is §5's three: `hit`, `miss`, `coalesced`. `status` is a code
  family (`2xx`, `4xx`, …) and `unknown` for a request that died before it had
  one — Bandit emits its stop event either way, and `AudioProxy.LogHandler`
  has the story of why that is not hypothetical.

  ## Label discipline is a hard rule, not a style

  Every label value here comes from a bounded enum this codebase defines — a
  format, an outcome, an endpoint class, a status family. Nothing derived from
  a request reaches a label: not the source, not the options string, not the
  cache key. A label whose values a client chooses is a series count a client
  chooses, and the failure mode is the scraper's storage rather than this
  process' — which is exactly why the rule belongs at the point of
  instrumentation and not in the scraper's config.

  `renders_running` counts *coordinators*, so it counts renders and not
  requests: twenty clients coalesced onto one encode are one running render,
  which is the same thing `AP_MAX_CONCURRENCY` counts.

  ## A handler that raises is a handler that stops existing

  The same hazard `AudioProxy.LogHandler` documents, and the same defence:
  `:telemetry` detaches a raising handler permanently and silently, so one
  malformed event would cost every future metric rather than one. Every read
  of an event's payload falls back rather than matching, and `handle_event/4`
  rescues on top of that.
  """

  use GenServer

  require Logger

  alias AudioProxy.{RenderCoordinator, Semaphore, Telemetry}
  alias AudioProxy.Metrics.Exposition

  @table __MODULE__
  @handler_id __MODULE__

  @bandit_stop [:bandit, :request, :stop]

  # Render-appropriate edges, exponential-ish, reaching the default
  # `AP_RENDER_TIMEOUT` so that a render which timed out lands in a finite
  # bucket rather than in `+Inf` with everything else. Fixed rather than
  # configurable: a bucket set that changes between deployments makes a
  # histogram unaggregatable across them, which is the one thing an operator
  # running more than one node needs it to be.
  @buckets [0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0]

  # A histogram series is one ETS row: `{key, sum_micros, b0, b1, …, b_inf}`.
  # See `observe/3` — the shape exists so that an observation is a single
  # atomic `update_counter`, which is what keeps `_sum` and the buckets from
  # ever disagreeing under a concurrent scrape. `@histogram_row` is the
  # zeroed default a first observation creates; `@histogram_pattern` is the
  # same arity with wildcards, for reading the series back.
  @histogram_slots length(@buckets) + 2
  @histogram_row List.to_tuple([nil | List.duplicate(0, @histogram_slots)])
  @histogram_pattern List.to_tuple([nil | List.duplicate(:_, @histogram_slots)])

  # A scrape must not outlive the interval that triggered it, and a wedged
  # semaphore is a thing to report rather than to wait for. Sized like
  # `AudioProxy.Readiness`'s probe budget, and for the same reason.
  @sample_timeout 1_000

  @definitions [
    %{
      name: "audio_proxy_renders_total",
      type: :counter,
      labels: [:format, :outcome],
      help: "Renders that finished, by output format and outcome.",
      source: :counted
    },
    %{
      name: "audio_proxy_render_duration_seconds",
      type: :histogram,
      labels: [:format, :outcome],
      buckets: @buckets,
      help: "Wall-clock seconds from the start of a render to its outcome.",
      source: :counted
    },
    %{
      name: "audio_proxy_renders_running",
      type: :gauge,
      help: "Renders in flight. Coalesced requests share one, so this counts renders.",
      source: :sampled
    },
    %{
      name: "audio_proxy_render_slots_held",
      type: :gauge,
      help: "Render slots currently held.",
      source: :sampled
    },
    %{
      name: "audio_proxy_render_slots_capacity",
      type: :gauge,
      help: "Render slots available in total (AP_MAX_CONCURRENCY).",
      source: :sampled
    },
    %{
      name: "audio_proxy_render_queue_depth",
      type: :gauge,
      help: "Requests waiting for a render slot.",
      source: :sampled
    },
    %{
      name: "audio_proxy_render_queue_capacity",
      type: :gauge,
      help: "Requests that may wait for a render slot (AP_QUEUE_SIZE).",
      source: :sampled
    },
    %{
      name: "audio_proxy_render_queue_rejections_total",
      type: :counter,
      help: "Requests refused a render slot because the wait queue was full.",
      source: :counted
    },
    %{
      name: "audio_proxy_cache_lookups_total",
      type: :counter,
      labels: [:format, :outcome],
      help: "Variant lookups by outcome: hit, miss, or coalesced onto a running render.",
      source: :counted
    },
    %{
      name: "audio_proxy_variant_store_write_failures_total",
      type: :counter,
      help: "Completed renders the variant store refused to keep.",
      source: :counted
    },
    %{
      name: "audio_proxy_http_requests_total",
      type: :counter,
      labels: [:endpoint, :status],
      help: "HTTP requests by endpoint class and status code family.",
      source: :counted
    }
  ]

  @doc "Starts the aggregator, creating its table and attaching its handler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Every metric this module exports, in exposition order.

  Public so that a test can assert the set has not changed by accident, and so
  that the README's table has one source it can be checked against.
  """
  @spec definitions() :: [Exposition.definition()]
  def definitions, do: @definitions

  @doc "The bucket edges of `audio_proxy_render_duration_seconds`, in seconds."
  @spec buckets() :: [float()]
  def buckets, do: @buckets

  @doc """
  Renders the current state as a Prometheus exposition.

  Samples the gauges as it goes, so what it returns is a snapshot taken now
  rather than a replay of the last event.
  """
  @spec scrape() :: iodata()
  def scrape do
    Exposition.render(@definitions, Map.merge(counted(), sampled()))
  end

  @doc """
  Discards every counted value. For tests only.

  Sampled gauges are unaffected — there is nothing here to reset, since they
  are read from the semaphore and the registry at scrape time.

  Not atomic, and deliberately left that way. Clearing and re-seeding are two
  operations, and an event landing between them creates a counter that
  `seed/0`'s `insert_new` will not then flatten — so that series survives the
  reset at 1. Every caller is a test, the suite's metrics tests are
  `async: false`, and a lock around a test helper would be machinery for a
  race that production cannot reach: nothing on the request path calls this.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    seed()
  end

  ## Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # `:public` because the handlers write from the emitting process, and
    # `write_concurrency` because they write from all of them at once.
    # `decentralized_counters` is what makes `:ets.update_counter/4` scale past
    # a couple of schedulers rather than serialising on one cache line.
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    events =
      [@bandit_stop, Telemetry.cache_lookup_event(), Telemetry.store_write_failure_event()] ++
        Telemetry.render_events() ++ Semaphore.events()

    # Detached first, and this is load-bearing rather than tidy. A handler is
    # global and outlives the process that attached it — `terminate/2` takes it
    # down on an ordinary stop, but not on a brutal kill, where nothing runs at
    # all. The handler left behind then holds a reference to a table that died
    # with its owner, so every event raises into the rescue below and the log
    # fills while nothing is counted. Worse, `attach_many/4` answers
    # `{:error, :already_exists}` for the taken id, which this asserted against
    # `:ok` — so the restart crashed too, and the third one exhausted the
    # supervisor's intensity and took the whole application down. One kill was
    # enough to do it. Detaching makes the restart total, and guarantees the
    # handler that ends up attached is pointed at the table this `init/1` just
    # created.
    _ = :telemetry.detach(@handler_id)

    :ok = :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil)

    seed()

    {:ok, %{}}
  end

  # An unlabeled counter starts at zero rather than at absent, so that
  # `rate(audio_proxy_render_queue_rejections_total[5m])` on a node that has
  # never rejected anything is `0` rather than no data — an alert that cannot
  # distinguish "nothing is wrong" from "nothing is reporting" is not an alert.
  # A labeled counter cannot get the same treatment: its label values are not
  # known until something happens, which is the ordinary Prometheus bargain.
  defp seed do
    for %{name: name, source: :counted, type: :counter} = definition <- @definitions,
        definition[:labels] in [nil, []] do
      :ets.insert_new(@table, {{:counter, name, []}, 0})
    end

    :ok
  end

  @impl true
  def terminate(_reason, state) do
    _ = :telemetry.detach(@handler_id)
    state
  end

  ## Events

  @doc false
  @spec handle_event(:telemetry.event_name(), map(), map(), term()) :: :ok
  def handle_event(event, measurements, metadata, config) do
    record(event, measurements, metadata, config)
    :ok
  rescue
    exception ->
      # See the moduledoc: dying here would take every future metric with it.
      Logger.error("metrics handler failed on #{inspect(event)}: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.error("metrics handler failed on #{inspect(event)}: #{kind} #{inspect(reason)}")
      :ok
  end

  # `:start` is not counted. The gauge it would have fed is sampled instead,
  # and a counter of renders started tells an operator nothing a counter of
  # renders finished does not — except during the seconds one is running, which
  # is what the gauge is for.
  defp record([:audio_proxy, :render, :start], _measurements, _metadata, _config), do: :ok

  defp record([:audio_proxy, :render, :stop], measurements, metadata, _config) do
    finished(measurements, metadata, outcome(metadata[:outcome]))
  end

  defp record([:audio_proxy, :render, :exception], measurements, metadata, _config) do
    finished(measurements, metadata, label(metadata[:class]))
  end

  defp record([:audio_proxy, :cache, :lookup], _measurements, metadata, _config) do
    count("audio_proxy_cache_lookups_total", [label(metadata[:format]), label(metadata[:status])])
  end

  defp record([:audio_proxy, :variant_store, :write_failure], _measurements, _metadata, _config) do
    count("audio_proxy_variant_store_write_failures_total", [])
  end

  defp record([:audio_proxy, :semaphore, :rejected], _measurements, _metadata, _config) do
    count("audio_proxy_render_queue_rejections_total", [])
  end

  # The semaphore's other events feed gauges this module samples instead, so
  # they are attached and deliberately ignored: attaching to the whole set
  # means a new event cannot arrive here as an unmatched clause and take the
  # handler down with it. `:displaced` arrived exactly that way — through
  # `Semaphore.events/0`, into this clause, with no edit here — which is the
  # arrangement working rather than a gap in it.
  defp record([:audio_proxy, :semaphore, _other], _measurements, _metadata, _config), do: :ok

  defp record(@bandit_stop, _measurements, %{conn: conn}, _config) do
    count("audio_proxy_http_requests_total", [
      conn.assigns |> Map.get(:endpoint_class, :unknown) |> label(),
      family(conn.status)
    ])
  end

  # Bandit omits `conn` when it could not build one — a malformed request line,
  # a TLS handshake that never became HTTP. There is no endpoint to attribute it
  # to, and `endpoint="unknown"` would put transport noise in the same series as
  # a genuine 404.
  defp record(@bandit_stop, _measurements, _metadata, _config), do: :ok

  # Unreachable through `attach_many/4`, which only subscribes this handler to
  # the events matched above — and here anyway, because the cost of being wrong
  # is not one dropped sample. An unmatched event is a `FunctionClauseError`,
  # which the rescue turns into a `Logger.error` *per event*: at render rates
  # that is the log, and the thing it is shouting about is a metric nobody
  # asked for yet. The day `Telemetry.render_events/0` grows a fourth name,
  # this is the difference between silence and a flood.
  defp record(_event, _measurements, _metadata, _config), do: :ok

  defp finished(measurements, metadata, outcome) do
    labels = [label(metadata[:format]), outcome]

    count("audio_proxy_renders_total", labels)
    observe("audio_proxy_render_duration_seconds", labels, measurements[:duration])
  end

  # `:ok` is what the span calls a render the client received whole; `success`
  # is what a Prometheus query calls it, and the spec's scenario names it that.
  defp outcome(:ok), do: "success"
  defp outcome(other), do: label(other)

  defp label(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp label(value) when is_binary(value), do: value
  defp label(_absent), do: "unknown"

  # Families rather than codes: a status label with 40 values is 40 series per
  # endpoint, and nothing an operator alerts on needs to tell a 401 from a 404
  # — the log line already carries the error class for the request that wants
  # explaining.
  defp family(status) when is_integer(status) and status in 100..599 do
    "#{div(status, 100)}xx"
  end

  defp family(_absent), do: "unknown"

  ## Counted values

  defp count(name, labels), do: bump({:counter, name, labels})

  # One row per series, one update per observation. The sum and the bucket used
  # to be two keys and two `update_counter` calls, which left a window a scrape
  # could land in: bucket incremented, sum not yet, and the exposition showed a
  # histogram whose `_sum` was short of what its `_count` implied. Impossible
  # arithmetic, self-correcting on the next scrape, and exactly the kind of
  # thing nobody diagnoses.
  #
  # `:ets.update_counter/4` applies a *list* of position operations to a single
  # key atomically, which removes the window rather than narrowing it. Position
  # 2 is the sum in microseconds; 3 onward are the buckets, one slot per edge
  # plus the `+Inf` overflow. No separate count: the exposition already derives
  # it by accumulating the buckets, and a second copy is a second thing to
  # disagree.
  defp observe(name, labels, duration) when is_integer(duration) and duration >= 0 do
    micros = System.convert_time_unit(duration, :native, :microsecond)
    key = {:histogram, name, labels}

    :ets.update_counter(
      @table,
      key,
      [{2, micros}, {3 + bucket_index(micros), 1}],
      put_elem(@histogram_row, 0, key)
    )
  end

  # A measurement that is not a duration is not an observation. Counting it as
  # zero would pull every latency quantile down — a silent lie is worse than a
  # count that does not match `renders_total`, which at least shows up as one.
  defp observe(_name, _labels, _absent), do: :ok

  defp bump(key, by \\ 1) do
    :ets.update_counter(@table, key, {2, by}, {key, 0})
  end

  # The index of the first bucket whose edge the observation falls at or below,
  # or the `+Inf` overflow at the end. Written against microseconds so the
  # comparison is integer arithmetic on a path that runs once per render.
  defp bucket_index(micros) do
    Enum.find_index(@buckets, &(micros <= trunc(&1 * 1_000_000))) || length(@buckets)
  end

  defp counted do
    @definitions
    |> Enum.filter(&(&1.source == :counted))
    |> Map.new(fn definition -> {definition.name, series(definition)} end)
  end

  defp series(%{type: :histogram} = definition) do
    @table
    |> :ets.match_object(put_elem(@histogram_pattern, 0, {:histogram, definition.name, :_}))
    |> Enum.map(fn row ->
      [{:histogram, _name, labels}, micros | buckets] = Tuple.to_list(row)

      {labels, %{buckets: buckets, sum: micros / 1_000_000}}
    end)
  end

  defp series(definition) do
    Enum.map(:ets.match(@table, {{:counter, definition.name, :"$1"}, :"$2"}), fn [labels, value] ->
      {labels, value}
    end)
  end

  ## Sampled values

  defp sampled do
    Map.merge(running(), semaphore())
  end

  # Guarded the same way the semaphore is, and for the same reason: both are
  # "ask another process", and a scrape that dies because one of them is
  # momentarily unavailable takes every *other* metric with it — including the
  # counters, which were sitting in ETS and answerable throughout. The
  # asymmetry was unintentional; `Registry.count/1` exits if the registry is
  # not running, and that exit propagated straight out of `scrape/0`.
  defp running do
    %{"audio_proxy_renders_running" => [{[], RenderCoordinator.in_flight()}]}
  catch
    :exit, _reason ->
      Logger.warning("coalescing registry did not answer; scrape omits renders_running")

      %{}
  end

  defp semaphore do
    stats = Semaphore.stats(Semaphore, @sample_timeout)

    %{
      "audio_proxy_render_slots_held" => [{[], stats.held}],
      "audio_proxy_render_slots_capacity" => [{[], stats.capacity}],
      "audio_proxy_render_queue_depth" => [{[], stats.queued}],
      "audio_proxy_render_queue_capacity" => [{[], stats.queue_size}]
    }
  catch
    # See the moduledoc: four gauges missing from one scrape is a gap a scraper
    # understands. The capacities could be read from `AudioProxy.Config` here,
    # and deliberately are not — half a sample from a different source, sitting
    # next to an occupancy nobody could read, is worse than none.
    :exit, _reason ->
      Logger.warning(
        "semaphore did not answer within #{@sample_timeout}ms; scrape omits its gauges"
      )

      %{}
  end
end
