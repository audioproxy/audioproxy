defmodule AudioProxy.RenderCoordinator do
  @moduledoc """
  One render per in-flight cache key, shared by everyone who asks for it.

  API doc §5: concurrent requests for the same not-yet-cached variant must not
  each spawn an encoder. This is the single-flight in front of
  `AudioProxy.Ffmpeg.Render` — a `Registry` of unique cache keys, a coordinator
  process per key, and a `DynamicSupervisor` holding them.

  ## Subscribing

  `subscribe/2` either starts the render or attaches to the running one:

      {:ok, :miss, render, []}          # this caller started it
      {:ok, :coalesced, render, chunks} # it was already running; `chunks` is the catch-up

  `render` is the coordinator's pid and stands where `AudioProxy.Ffmpeg.Render`'s
  did. It broadcasts the pipeline's own contract, with itself as the handle:

    * `{:chunk, render, binary}`
    * `{:done, render, %{exit_status: 0}}`
    * `{:error, render, failure}`

  So a consumer written against the pipeline works here unchanged, except for
  the two calls that name a handle: `Render.ack/2` has no counterpart (see
  *Backlog* below) and `Render.cancel/1` becomes `unsubscribe/1`, because a
  subscriber leaving must not cancel a render other subscribers are still
  reading.

  ## The slot comes first

  A coordinator does not spawn its render until `AudioProxy.Semaphore` grants it
  a slot, and releases that slot from `terminate/2` — so the cap counts renders
  rather than requests, and a variant twenty clients are waiting on costs one.

  It asks with `Semaphore.request/1` rather than the blocking `acquire/1`,
  because this process must keep answering joins while it waits: the requests
  coalescing onto a queued render are exactly the ones that should not each take
  a slot of their own. So a coordinator has one phase more than the render does
  — `:queued`, before `:rendering` — and a subscriber cannot tell them apart,
  which is the point. It is waiting for bytes either way.

  The slot is asked for in `init/1`, which is what makes a full queue a *start*
  failure rather than a render failure: `subscribe/2` answers
  `{:error, {:queue_full, retry_after}}` and no coordinator is left registered
  under that key, so the next request asks the semaphore again instead of
  joining something that is never going to render. `AudioProxy.ErrorJSON`
  already renders that tuple as §5's 429, `Retry-After` and all.

  ## The start race

  Starting and joining are the same call. `DynamicSupervisor.start_child/2`
  either succeeds — this caller is the MISS, and its pid is already in the
  subscriber list before `init/1` returns, so no chunk can be produced before
  it is listening — or answers `{:error, {:already_started, pid}}`, which is
  the COALESCED path and a join.

  The join is a `call` that returns the backlog *and* registers the subscriber
  in one callback. That atomicity is the whole seam: a joiner cannot be handed
  a backlog and then miss the chunk that was broadcast while it was being
  handed one, and cannot be registered first and receive a chunk it will also
  find in its backlog.

  Losing the race to a coordinator that is stopping — a finished render past
  its linger, a failed one that has already unregistered — is a caught exit and
  a retry, which starts a fresh render.

  ## Backlog, and the memory bound

  Everything the render produces is retained, in order, so a subscriber that
  joins at any point receives the whole stream. Retaining it is not a cost the
  coalescing imposes: the variant-cache slice tees the same bytes to storage.

  Because the bytes are held anyway, the pipeline is acknowledged the moment a
  chunk arrives, and the pipeline's own high-water mark stops being the bound.
  What bounds this instead is `AP_MAX_VARIANT_BYTES`: a render whose output
  passes it fails for every subscriber rather than growing without limit. It is
  a ceiling on the *variant*, separate from `AP_MAX_SRC_BYTES`'s ceiling on the
  source, so a deployment can accept two-hour masters and still bound one
  render's retention to a preview's worth of bytes. It defaults to the
  effective `AP_MAX_SRC_BYTES`, so a deployment that sets neither is bounded
  exactly where it was before the two were separated.

  The breach is only detectable once the response has committed to `200` and
  begun streaming, so it is a failed request rather than a `413` — the source
  ceiling stays the only one enforced before a render starts. That is the
  reason the escalation is written down: the named-pipe (FIFO) pattern in
  `AudioProxy.Ffmpeg.Render`'s moduledoc spools instead of retaining, and
  nothing in the contract above changes when it lands.

  Raising the ceiling does not buy capacity. It bounds one render while the
  bill is `AP_MAX_CONCURRENCY × backlog`, so raising it licenses every slot to
  reach the larger figure — which turns one killed render into an exhausted
  container. `docs/capacity.md` has the arithmetic.

  ## Teardown

  Three ways this ends, and they differ in what happens to the key:

    * **Done** — the completion is broadcast, then the coordinator lingers
      briefly, still registered, so a request that passed its cache check a
      moment too late still gets the finished bytes instead of re-rendering.
    * **Failure** — broadcast to every current subscriber, then the key is
      unregistered *immediately*, so the next request retries rather than
      attaching to a corpse.
    * **Last subscriber gone** — nobody is listening, so the subprocess is
      cancelled. `unsubscribe/1` returns only once that has happened, which is
      what makes it usable as a barrier the way `Render.cancel/1` is.

  One subscriber dying never affects the others: it is removed and the render
  continues.

  ## The write-back tee is a subscriber

  When a variant store is configured and the spec carries `:metadata`, the
  coordinator starts an `AudioProxy.VariantStore.Tee` and registers it like
  any other subscriber — before the first chunk can exist, so the store
  receives the whole stream. That one fact is the disconnect policy: with a
  store, the last *client* leaving still leaves the tee counted, so the render
  completes into the store and the next request is a HIT; without one, the
  subscriber count reaches zero and the render is cancelled as before. A tee
  that dies is forgotten like any subscriber — and if no client remains
  either, the render is cancelled, because nothing is left that could profit
  from it.

  It starts with the *render*, not with the coordinator, which is only
  visible while a slot is being waited for. A queued coordinator has no tee,
  so a queued render every client has abandoned stops rather than holding its
  place to encode for the cache alone — which would spend a slot, under
  exactly the contention that made it queue, on a render no client wants.
  """

  use GenServer

  require Logger

  alias AudioProxy.{Config, Semaphore}
  alias AudioProxy.Ffmpeg.{Render, RenderSupervisor}
  alias AudioProxy.VariantStore
  alias AudioProxy.VariantStore.Tee

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  # How long a finished coordinator stays registered. Long enough to catch a
  # request that was already in flight when the render completed, short enough
  # that a hot key does not keep its bytes resident. A straggler that misses it
  # starts a fresh render — wasteful, never wrong.
  @linger 1_000

  # Joining is a message to a live process that does no I/O in the callback, so
  # this only ever expires on a coordinator that is wedged.
  @join_timeout 5_000

  # Leaving can block on the pipeline's kill discipline, which is `Render`'s
  # own worst case plus margin. A timeout here would hand back `:ok` for a
  # subprocess still being killed, so it is set above that worst case rather
  # than at something request-shaped.
  @unsubscribe_timeout 15_000

  # Added to what `terminate/2` can block on for this process' shutdown budget,
  # so it can always finish the work it started. See `child_spec/1`.
  @shutdown_margin 2_000

  # Retries of the whole start-or-join loop. Each one either starts a render or
  # joins a live coordinator; only a coordinator stopping in the window between
  # the two costs an attempt, so exhausting five means something is wrong that
  # retrying will not fix.
  @attempts 5

  @typedoc "The coordinator, which is also the handle in the messages above."
  @type t :: pid()

  @typedoc "Whether this subscriber started the render or attached to it."
  @type status :: :miss | :coalesced

  @typedoc """
  How to render, when this subscriber turns out to be the one starting it.

  The options of `AudioProxy.Ffmpeg.Render.start_link/1` less `:consumer`,
  which is the coordinator itself — plus `:metadata`
  (`t:AudioProxy.VariantStore.metadata/0`), which never reaches the pipeline:
  it is what the write-back tee stores alongside the bytes, and without it no
  tee is started.
  """
  @type render_spec :: keyword()

  @typedoc """
  What a subscriber receives.

  The pipeline's own three, plus `{:rendering, _}` — sent only to subscribers
  that were attached while this coordinator was waiting for a render slot, and
  meaning "bytes are now possible". A consumer that measures how long the
  render has been silent needs it, because until then there was no render. One
  that does not may ignore it.
  """
  @type message ::
          {:rendering, t()}
          | {:chunk, t(), binary()}
          | {:done, t(), %{exit_status: 0}}
          | {:error, t(), Render.failure()}

  defstruct [
    :key,
    :spec,
    :metadata,
    :render,
    :render_monitor,
    :info,
    :linger_timer,
    phase: :rendering,
    subscribers: %{},
    backlog: [],
    bytes: 0
  ]

  @doc """
  The registry and supervisor this module needs, for the application tree.

  Start them after `AudioProxy.Ffmpeg.RenderSupervisor`: a coordinator spawns a
  render in `init/1`, and shutdown then tears the coordinators down first.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  @doc """
  How many renders are in flight right now.

  One per registered cache key, which is the same thing `AP_MAX_CONCURRENCY`
  counts: the twenty requests coalesced onto one encode are one render here.
  `AudioProxy.Metrics` samples it per scrape rather than maintaining a gauge
  from the render events, because a registry entry cannot outlive the process
  that holds it — an abnormal exit corrects this number for free, where an
  event-driven counter would be permanently one too high.

  Briefly includes a coordinator that has finished and not yet unregistered,
  which is the same window that lets a late request coalesce onto its backlog.
  """
  @spec in_flight() :: non_neg_integer()
  def in_flight, do: Registry.count(@registry)

  @doc """
  Subscribes the calling process to the render for `cache_key`, starting it
  from `spec` if it is not already running.

  Returns `{:ok, status, render, backlog}`. `backlog` is the bytes produced
  before this subscriber attached, in order, and is always empty for a `:miss`;
  a consumer must deliver it before the chunks that follow.

  Errors are the pipeline's own — `{:error, :ffmpeg_not_found}` and friends —
  plus `{:error, {:queue_full, retry_after}}` when `AudioProxy.Semaphore` had
  neither a slot nor room to wait, and `{:error, :coordinator_unavailable}` if
  the start-or-join loop could not settle, which means something is repeatedly
  killing coordinators.
  """
  @spec subscribe(String.t(), render_spec()) ::
          {:ok, status(), t(), [binary()]} | {:error, term()}
  def subscribe(cache_key, spec) when is_binary(cache_key) and is_list(spec) do
    start_or_join(cache_key, spec, @attempts)
  end

  @doc """
  Detaches the calling process from `render`.

  The render continues for whoever is left. If nobody is, it is cancelled and
  its subprocess killed before this returns — so, like
  `AudioProxy.Ffmpeg.Render.cancel/1`, this is a barrier and not a request.

  Detaching from a coordinator that has already stopped is `:ok`: that is the
  outcome asked for.
  """
  @spec unsubscribe(t()) :: :ok
  def unsubscribe(render) do
    GenServer.call(render, :unsubscribe, @unsubscribe_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Never restarted, for the same reason a render is not: the byte stream
      # is gone and every subscriber has already been told.
      restart: :temporary,
      # Derived, not chosen, and derived from *both* calls `terminate/2` makes.
      # A budget below `Render.cancel/1`'s own timeout means the supervisor
      # brutal-kills this process mid-cancel on exactly the renders that need
      # cancelling most — the ones whose subprocess is ignoring SIGTERM. The
      # subprocess still dies (the pipeline monitors its consumer), but the
      # kill would be racing the guarantee instead of implementing it. The
      # release that follows the cancel has a bound of its own, and leaving it
      # out would put the sum back over the budget in the one case where both
      # are slow.
      shutdown: Render.cancel_timeout() + Semaphore.release_timeout() + @shutdown_margin
    }
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :key)))
  end

  defp via(key), do: {:via, Registry, {@registry, key}}

  defp start_or_join(_key, _spec, 0), do: {:error, :coordinator_unavailable}

  defp start_or_join(key, spec, attempts) do
    child = {__MODULE__, key: key, spec: spec, subscriber: self()}

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} ->
        {:ok, :miss, pid, []}

      {:error, {:already_started, pid}} ->
        case join(pid) do
          {:ok, backlog} -> {:ok, :coalesced, pid, backlog}
          :gone -> start_or_join(key, spec, attempts - 1)
        end

      # `init/1` refuses a render it could not start as a `:shutdown` stop, so
      # a missing ffmpeg is an error tuple rather than a crash report on every
      # request. Unwrapped here, so callers see the pipeline's own reason.
      {:error, {:shutdown, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join(pid) do
    GenServer.call(pid, {:join, self()}, @join_timeout)
  catch
    # Stopping between the registry lookup and this call. Retrying starts a
    # fresh render, which is correct — the key is on its way out.
    :exit, _reason -> :gone
  end

  ## Server

  @impl true
  def init(opts) do
    # So that the supervisor's shutdown is a stop like any other and reaches
    # `terminate/2`, where the subprocess is killed.
    Process.flag(:trap_exit, true)

    key = Keyword.fetch!(opts, :key)
    {metadata, spec} = Keyword.pop(Keyword.fetch!(opts, :spec), :metadata)
    subscriber = Keyword.fetch!(opts, :subscriber)

    state = %__MODULE__{
      key: key,
      spec: spec,
      metadata: metadata,
      # Registered before the first chunk can exist, so the subscriber that
      # started this render needs no backlog. The tee is registered the same
      # way, but not here — see `spawn_render/1`.
      subscribers: %{subscriber => Process.monitor(subscriber)}
    }

    # Asked for here rather than after `init/1` returns, so that a full queue is
    # a `start_child` error the requesting process gets back directly — a 429
    # before a coordinator exists, rather than a coordinator whose only act is
    # to broadcast a failure. `request/1` answers immediately whichever way it
    # goes; only the *waiting* would block, and that is what `:queued` is.
    #
    # Before the tee, too: a coordinator that cannot get a slot stops without
    # ever running `terminate/2`, and it should not have opened a staging file
    # for a render that will not happen.
    case Semaphore.request() do
      :granted ->
        start_render(state)

      :queued ->
        {:ok, %{state | phase: :queued}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  # Started from `init/1`, so a start failure can still be a `{:stop,
  # {:shutdown, _}}` that `start_or_join/3` unwraps into the caller's own
  # `{:error, reason}`: no ffmpeg on `PATH` is a 500 with the reason in the log
  # and no crash report per request, exactly as it was before slots existed.
  defp start_render(state) do
    case spawn_render(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  # Started from a grant that arrived after `init/1` returned. The caller has
  # long since been handed a coordinator, so the only way left to report a
  # start failure is the failure broadcast every other failure uses.
  defp start_granted_render(state) do
    case spawn_render(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        fail(state, %{
          class: :render_failed,
          exit_status: nil,
          detail: "could not start render: #{inspect(reason)}"
        })
    end
  end

  # Announced on every transition into `:rendering`, including the one that
  # happens inside `init/1` where there was no wait at all. A consumer's budget
  # for "the render has said nothing" cannot start when it subscribed, because
  # between subscribing and a byte being *possible* there may have been a queue;
  # this is the moment it becomes possible, and it has to be reported the same
  # way whether the queue was empty or not — a consumer that only heard about
  # the slow case would have to guess about the fast one.
  #
  # The tee is started here rather than in `init/1`, which is where the slot and
  # the write-back meet. Registering it before the render is spawned keeps the
  # guarantee it was given — no chunk can exist yet, so it needs no backlog —
  # while keeping its lifetime the render's rather than this process'. Starting
  # it while queued would open a staging file for a render that has not begun,
  # against a deadline of its own that assumes one has; worse, it would count as
  # a subscriber, so a queued render every client had abandoned would hold its
  # place, take a slot, and encode for the cache alone. Nothing designed that,
  # and under contention it is a slot taken from a request that has a client.
  defp spawn_render(state) do
    state = %{state | subscribers: maybe_tee(state.subscribers, state.key, state.metadata)}

    case RenderSupervisor.start_render(Keyword.put(state.spec, :consumer, self())) do
      {:ok, render} ->
        state = %{
          state
          | phase: :rendering,
            render: render,
            render_monitor: Process.monitor(render)
        }

        broadcast(state, {:rendering, self()})

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The tee exists exactly when there is somewhere to write and something to
  # write it with. Failing to start one is logged, not fatal: the render and
  # its clients owe nothing to the cache.
  defp maybe_tee(subscribers, key, metadata) do
    if metadata != nil and VariantStore.configured?() do
      case Tee.start(self(), key, metadata) do
        {:ok, tee} ->
          Map.put(subscribers, tee, Process.monitor(tee))

        {:error, reason} ->
          Logger.warning("could not start variant store tee: #{inspect(reason)}")
          subscribers
      end
    else
      subscribers
    end
  end

  # `:queued` and `:rendering` are one thing from a subscriber's side: bytes are
  # coming, and none have arrived that this joiner is missing. They differ in
  # one respect only, and it is not about the bytes — a joiner that arrives
  # while the render is already under way never queued, so it is told so here
  # rather than waiting for the announcement it has already missed. Sent before
  # the reply, so it is in the joiner's mailbox by the time it starts reading.
  @impl true
  def handle_call({:join, pid}, _from, %__MODULE__{phase: :rendering} = state) do
    send(pid, {:rendering, self()})

    {:reply, {:ok, backlog(state)}, monitor_subscriber(state, pid)}
  end

  def handle_call({:join, pid}, _from, %__MODULE__{phase: :queued} = state) do
    {:reply, {:ok, backlog(state)}, monitor_subscriber(state, pid)}
  end

  # The render is over and every byte is in the backlog, so this joiner is
  # complete the moment it has it. The terminal message is sent before the
  # reply and therefore lands in the caller's mailbox first; `GenServer.call/3`
  # selects on its own ref, so the joiner still gets the backlog first and
  # finds `{:done, _, _}` waiting when it starts consuming.
  def handle_call({:join, pid}, _from, %__MODULE__{phase: :completed} = state) do
    send(pid, {:done, self(), state.info})

    {:reply, {:ok, backlog(state)}, state}
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    case forget_subscriber(state, pid) do
      %__MODULE__{phase: phase, subscribers: subscribers} = state
      when phase in [:queued, :rendering] and map_size(subscribers) == 0 ->
        # Nobody is reading. Replying from `terminate/2`'s far side is what
        # makes this a barrier: the subprocess is gone before the caller runs.
        {:stop, :normal, :ok, state}

      state ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:chunk, render, data}, %__MODULE__{render: render} = state) do
    # Acknowledged immediately: the bytes are retained here regardless, so the
    # pipeline's high-water mark would only stall a stream this process has
    # already paid the memory for. The backlog cap is the bound instead.
    Render.ack(render, byte_size(data))

    case retain(state, data) do
      {:ok, state} ->
        broadcast(state, {:chunk, self(), data})
        {:noreply, state}

      {:error, failure} ->
        fail(state, failure)
    end
  end

  def handle_info({:done, render, info}, %__MODULE__{render: render} = state) do
    broadcast(state, {:done, self(), info})

    Process.demonitor(state.render_monitor, [:flush])

    # Here, not in `terminate/2`. A slot caps *encoders*, and this one's is
    # gone: `{:done, _, _}` arrives after the subprocess has exited and every
    # byte it wrote has been forwarded. What the linger below keeps alive is a
    # buffer being served from memory, which costs no CPU and must not cost a
    # slot — holding one across it would shrink effective concurrency by the
    # linger over the render's own duration, which for the preview-sized
    # renders v1 targets is most of it. `terminate/2` still releases, for the
    # paths that never get here; the second call is a no-op.
    Semaphore.release()

    {:noreply,
     %{
       state
       | phase: :completed,
         info: info,
         render: nil,
         render_monitor: nil,
         linger_timer: Process.send_after(self(), :linger_expired, @linger)
     }}
  end

  def handle_info({:error, render, failure}, %__MODULE__{render: render} = state) do
    fail(state, failure)
  end

  # The pipeline died without saying anything — it cannot report its own crash.
  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %__MODULE__{render_monitor: monitor} = state
      ) do
    fail(state, %{
      class: :render_failed,
      exit_status: nil,
      detail: "render died without reporting: #{inspect(reason)}"
    })
  end

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    case forget_subscriber(state, pid) do
      %__MODULE__{phase: phase, subscribers: subscribers} = state
      when phase in [:queued, :rendering] and map_size(subscribers) == 0 ->
        {:stop, :normal, state}

      state ->
        {:noreply, state}
    end
  end

  # The slot came free. Nothing about this is visible to a subscriber: it has
  # been waiting for bytes, and still is.
  def handle_info({Semaphore, :granted}, %__MODULE__{phase: :queued} = state) do
    start_granted_render(state)
  end

  def handle_info(:linger_expired, state), do: {:stop, :normal, state}

  # The only link is the supervisor's, so this is the shutdown path. Stopping
  # rather than ignoring it is what lets `terminate/2` kill the subprocess.
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    # `cancel/1` returns once the subprocess is gone and tolerates a render that
    # already finished, so this is safe on every stop path.
    if state.render, do: Render.cancel(state.render)

    # After the cancel, not before: releasing first would hand the slot to a
    # waiter while this render's ffmpeg was still being killed, which is the
    # cap being exceeded by exactly the margin the kill discipline takes.
    #
    # Idempotent, and it covers a `:queued` coordinator that never held a slot
    # as well as one that did. The semaphore's own monitor is the backstop for
    # the stop paths that never reach here.
    Semaphore.release()
    :ok
  end

  ## Subscribers

  defp monitor_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
    end
  end

  defp forget_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp broadcast(state, message) do
    Enum.each(state.subscribers, fn {pid, _monitor} -> send(pid, message) end)
  end

  ## Backlog

  defp backlog(state), do: Enum.reverse(state.backlog)

  defp retain(state, data) do
    bytes = state.bytes + byte_size(data)
    limit = Config.get(:max_variant_bytes)

    if bytes > limit do
      {:error,
       %{
         class: :render_failed,
         exit_status: nil,
         detail: "render output exceeded the #{limit}-byte retention cap (AP_MAX_VARIANT_BYTES)"
       }}
    else
      {:ok, %{state | backlog: [data | state.backlog], bytes: bytes}}
    end
  end

  ## Failure

  # Told once to everyone currently attached, then the key goes immediately so
  # the next request renders again instead of joining something that is gone.
  defp fail(state, failure) do
    broadcast(state, {:error, self(), failure})
    Registry.unregister(@registry, state.key)

    {:stop, :normal, state}
  end
end
