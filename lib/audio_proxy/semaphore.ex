defmodule AudioProxy.Semaphore do
  @moduledoc """
  The render-slot budget: at most `AP_MAX_CONCURRENCY` renders at once, with at
  most `AP_QUEUE_SIZE` waiting behind them.

  ffmpeg is CPU-bound, so the number of encoders running at once is the one
  resource this proxy has to ration. Everything else — the coalescing registry,
  the bounded buffers, the kill discipline — assumes a slot was granted first.
  A request that cannot get one and cannot wait for one is a 429, which is the
  only place §5's `Retry-After` comes from.

  ## The server never blocks

  `request/1` is a `GenServer.call` that answers immediately with one of three
  outcomes:

    * `:granted` — a slot was free and the caller now holds it
    * `:queued` — the caller is in the wait queue and will receive
      `{AudioProxy.Semaphore, :granted}` when its turn comes
    * `{:error, {:queue_full, retry_after}}` — no slot, no room to wait

  Grants happen inside `release/1` and `DOWN` handling, never in a callback
  that waits for something. That is what lets a caller queue for minutes
  without the semaphore being unable to answer anyone else — including the
  releases that are the only way the queue ever moves.

  `acquire/1` is the blocking convenience on top: `request/1` plus a receive
  with the caller's own timeout. `AudioProxy.RenderCoordinator` uses `request/1`
  directly, because a coordinator that blocked waiting for a slot could not
  answer the joins that are coalescing onto it.

  ## Admission classes

  The wait queue is ordered rather than flat: `interactive > high > normal >
  low`. A freed slot goes to the *oldest waiter of the highest non-empty
  class*, and FIFO holds within a class, so `classes/0` is a tie-breaking order
  on top of arrival order rather than a replacement for it.

  `interactive` is the default, which is what makes the whole mechanism
  invisible: a caller that says nothing is in the one class nothing can outrank
  and nothing can displace, queued behind exactly the callers that were already
  in front of it. A workload where nobody speaks a class is plain FIFO, and
  `AudioProxy.SemaphorePropertyTest` compares it against a FIFO model to keep it
  that way. Nothing in this repository passes `:class` today; the classes exist
  for callers that have background work to defer — cache warming, batch
  rendering — and want it to yield to a live listener.

  When the queue is full, an arrival that outranks something queued displaces
  the *newest* waiter of the lowest non-`interactive` class present: the newest
  has waited least, so displacing it wastes the least sunk waiting. The victim
  receives `{AudioProxy.Semaphore, {:displaced, retry_after}}` — a reply
  distinct from queue-full, and retryable the same way. An arrival that
  outranks nothing queued is refused with `{:queue_full, retry_after}`, exactly
  as before.

  **Starvation of the lower classes is the contract, not a defect.** There is
  no aging: under sustained `interactive` load, `low` waits indefinitely and is
  displaced first. That is safe because deferred work is not lost — a render
  that never got its background slot is still rendered lazily the moment
  someone asks for it directly — and it is visible, because every event carries
  per-class depth. A scheduler that let batch work overtake a listener would be
  trading the one latency the proxy is judged on for throughput nobody is
  waiting on.

  ## One slot per process, released by exit if not by hand

  A holder is monitored, and its `DOWN` releases the slot — so a crashed render
  costs a slot for as long as the monitor takes to fire, and no longer. A queued
  waiter is monitored too, and its `DOWN` drops it from the queue, so a client
  that gives up while waiting does not get handed a slot nobody is holding.

  `release/1` is therefore a promptness optimisation rather than the guarantee,
  and it is idempotent: releasing twice, or releasing without holding, is `:ok`.
  The one thing the monitor cannot cover is a long-lived caller whose release
  did not reach a wedged semaphore — see `release/1`.
  Acquiring twice from one process is `{:error, :already_held}` — a slot is a
  process' budget, and a second one would be an accounting error rather than a
  deadlock worth waiting on.

  ## The caller-timeout race

  A grant can land in the window between `acquire/1`'s timeout firing and the
  caller doing anything about it. `acquire/1` closes it by releasing and then
  draining: `release/1` is synchronous, so by the time it returns the server has
  processed it and any grant it sent is already in the mailbox — the drain is
  exact rather than a race of its own.

  ## Configuration is read per operation

  Capacity and queue size come from `AudioProxy.Config` on every call, not from
  `init/1`. There is no reconfiguration at runtime, so in production this is
  just a `:persistent_term` read; in tests it means `put_config/1` takes effect
  without restarting a supervised process. Lowering capacity below the number of
  slots currently held grants nothing new until it drains, which is the only
  sensible reading of it.

  Tests that want a semaphore of their own can pass `:name`, `:capacity` and
  `:queue_size` to `start_link/1`, which pins them and skips the config read.

  ## `Retry-After`

  Derived from a moving average of recent slot-hold durations, scaled by how
  deep the queue already is: roughly "how long the renders in front of you have
  been taking, times how many of them there are, over how many run at once".
  Coarse by construction — §5 only requires the header to exist and be sane, and
  a client that retries a little early finds the queue full again and is told
  again. Before any render has completed there is nothing to average, so a
  placeholder stands in until the first one does.

  ## Events

  | Event | Measurements | When |
  |---|---|---|
  | `[:audio_proxy, :semaphore, :acquired]` | `held`, `queued`, `wait` | a slot was taken, immediately or after queueing |
  | `[:audio_proxy, :semaphore, :queued]` | `held`, `queued` | a caller joined the wait queue |
  | `[:audio_proxy, :semaphore, :rejected]` | `held`, `queued`, `retry_after` | the queue was full |
  | `[:audio_proxy, :semaphore, :released]` | `held`, `queued`, `duration` | a holder gave its slot back |
  | `[:audio_proxy, :semaphore, :abandoned]` | `held`, `queued` | a waiter left the queue before its turn |
  | `[:audio_proxy, :semaphore, :displaced]` | `held`, `queued`, `retry_after` | a waiter was displaced by a higher class |

  `held` and `queued` are the occupancy and depth *after* the event; `wait` and
  `duration` are native time units. Metadata is always `%{capacity:,
  queue_size:, class:}`, where `class` is the class of whoever the event is
  about — the caller granted, queued, rejected or displaced, or the holder that
  released. `:abandoned` is one more event than `design.md` listed, and it is
  here so that a queue draining by attrition — clients giving up — does not
  leave `queued` reading high until the next unrelated event.

  Every event also carries `queued_interactive`, `queued_high`, `queued_normal`
  and `queued_low`: the depth of *each* class, not just the one the event is
  about. Reporting only the event's own class would publish a `low` depth that
  goes stale for as long as `low` is starved — which is precisely the state an
  operator needs to see, and precisely when no `low` event fires.

  `AudioProxy.Metrics` counts `:rejected` from this set and takes its occupancy
  gauges from `stats/2` instead, so the accuracy of what it publishes does not
  depend on every event being seen.
  """

  use GenServer

  alias AudioProxy.Config

  @name __MODULE__

  @telemetry [:audio_proxy, :semaphore]

  # Highest first. The list *is* the order — grant scans it front to back,
  # eviction scans it back to front — so there is no separate rank table to
  # keep in step with it.
  @classes [:interactive, :high, :normal, :low]

  # `interactive` is not evictable: a listener's patience budget is not a
  # batch's to spend.
  #
  # Deliberately redundant. `victim/2` only ever considers classes *below* the
  # arrival, and nothing is below the top class — so with `interactive` first
  # in `@classes` this subtraction changes no outcome today, and removing
  # either lock on its own leaves the suite green (measured). It earns its keep
  # against the day a class is added above `interactive`, which would make a
  # listener displaceable through the ordering alone.
  @evictable @classes -- [:interactive]

  @empty_order Map.new(@classes, &{&1, :queue.new()})

  # Slot-hold durations kept for the `Retry-After` average. Enough to smooth a
  # single outlier, short enough to track a change in what is being rendered.
  @samples 20

  # How long `release/1` waits for the server before leaving the slot to the
  # monitor. Every callback here is O(1) or O(queue), so reaching this at all
  # means something is badly wrong; it is a bound, not a budget.
  @release_timeout 5_000

  # Stands in for the average until a render has actually completed. Nothing
  # measured is available at that point, and a wrong-but-small hint is better
  # than either no header or a fabricated large one; it self-corrects after the
  # first release.
  @default_hold_ms 2_000

  @typedoc "Seconds a rejected caller is told to wait. Always at least 1."
  @type retry_after :: pos_integer()

  @typedoc "An admission class. See *Admission classes* in the moduledoc."
  @type class :: :interactive | :high | :normal | :low

  @typedoc "What `request/2` answers. See the moduledoc."
  @type outcome ::
          :granted
          | :queued
          | {:error, {:queue_full, retry_after()}}
          | {:error, :already_held}

  @typedoc "Occupancy, for tests and for anyone asking rather than subscribing."
  @type stats :: %{
          held: non_neg_integer(),
          queued: non_neg_integer(),
          capacity: pos_integer(),
          queue_size: non_neg_integer()
        }

  defstruct [
    :capacity,
    :queue_size,
    held: %{},
    waiters: %{},
    order: @empty_order,
    samples: []
  ]

  @doc """
  Starts the semaphore.

  Options, all optional:

    * `:name` — defaults to this module, which is what the application tree
      starts and what every other function defaults to.
    * `:capacity`, `:queue_size` — pin the limits instead of reading
      `AP_MAX_CONCURRENCY` / `AP_QUEUE_SIZE` per operation. For tests that want
      a semaphore of their own; production uses the config.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Every event this module emits, for a consumer attaching to all of them.

  The same service `AudioProxy.Telemetry.render_events/0` performs for the
  render lifecycle, and for the same reason: a consumer that listed the names
  itself would go on working, silently short of one, the day a sixth is added.
  """
  @spec events() :: [:telemetry.event_name()]
  def events do
    Enum.map(
      [:acquired, :queued, :rejected, :released, :abandoned, :displaced],
      &(@telemetry ++ [&1])
    )
  end

  @doc """
  The admission classes, highest first.

  Public so that a caller choosing a class, or a consumer labelling a metric by
  one, reads the order off the module that enforces it rather than restating it.
  """
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  Asks for a slot for the calling process, answering immediately.

  See the moduledoc for the three outcomes. A `:queued` caller receives
  `{AudioProxy.Semaphore, :granted}` when a slot comes free, and must then treat
  itself as a holder — including releasing it. It may instead receive
  `{AudioProxy.Semaphore, {:displaced, retry_after}}`, which means a higher
  class took its place in a full queue and it is no longer waiting; only a
  caller that named a class below `interactive` can receive it.

  Options:

    * `:class` — one of `classes/0`, defaulting to `:interactive`. See
      *Admission classes* in the moduledoc.
  """
  @spec request(GenServer.server(), keyword()) :: outcome()
  def request(server \\ @name, opts \\ []) do
    GenServer.call(server, {:request, self(), class!(opts)})
  end

  defp class!(opts) do
    case Keyword.get(opts, :class, :interactive) do
      class when class in @classes ->
        class

      other ->
        raise ArgumentError,
              "unknown admission class #{inspect(other)}, expected one of #{inspect(@classes)}"
    end
  end

  @doc """
  Takes a slot for the calling process, waiting for one if the queue has room.

  Returns `:ok`, `{:error, {:queue_full, retry_after}}` when there was no room
  to wait, `{:error, {:displaced, retry_after}}` when a higher class took the
  place this caller was waiting in, `{:error, :timeout}` when `:timeout`
  elapsed first, or `{:error, :already_held}`. Options:

    * `:timeout` — how long to wait for a queued slot. Defaults to `:infinity`,
      because the thing that bounds a render is `AP_RENDER_TIMEOUT` and a
      shorter wait here would only turn a queued request into a failed one.
    * `:class` — the admission class, defaulting to `:interactive`. A caller
      that leaves it alone can never be displaced, so it never sees the
      `:displaced` error above.
    * `:server` — which semaphore, for tests running their own.

  A timeout releases whatever the race may have granted, so it does not leak a
  slot; see *The caller-timeout race* in the moduledoc, and `release/1` for the
  one case that release cannot cover.
  """
  @spec acquire(keyword()) :: :ok | {:error, term()}
  def acquire(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    timeout = Keyword.get(opts, :timeout, :infinity)

    case request(server, Keyword.take(opts, [:class])) do
      :granted -> :ok
      :queued -> await_grant(server, timeout)
      {:error, _reason} = error -> error
    end
  end

  defp await_grant(server, timeout) do
    receive do
      {__MODULE__, :granted} -> :ok
      {__MODULE__, {:displaced, retry_after}} -> {:error, {:displaced, retry_after}}
    after
      timeout ->
        release(server)

        # `release/1` is a call, so the server has already handled it and
        # anything it sent is in this mailbox. Nothing can arrive later. A
        # displacement is drained here too: it is the same stray message with
        # the same claim on the mailbox, and it is now moot either way.
        receive do
          {__MODULE__, :granted} -> :ok
          {__MODULE__, {:displaced, _retry_after}} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  @doc """
  How long `release/1` may block before it gives up and leaves the slot to the
  monitor.

  Public for the same reason `AudioProxy.Ffmpeg.Render.cancel_timeout/0` is: a
  caller that releases from its own `terminate/2` has to size its shutdown
  budget against this, and a hardcoded number there would drift the moment this
  one changes.
  """
  @spec release_timeout() :: pos_integer()
  def release_timeout, do: @release_timeout

  @doc """
  Gives back the calling process' slot, or removes it from the wait queue.

  Idempotent, and `:ok` even if the semaphore is not running — a caller
  releasing from its own `terminate/2` during shutdown must not crash because
  the semaphore stopped first.

  `:ok` here means "this caller is done with the slot", not "the semaphore has
  processed that". A dead semaphore has nothing to release into, and a wedged
  one that does not answer within `release_timeout/0` is caught the same way,
  which is deliberate: crashing the caller would achieve nothing the monitor is
  not already going to do. What recovers the slot in that second case is the
  holder exiting, so a *long-lived* caller that releases into a wedged
  semaphore does hold its slot until it dies. Every caller in this codebase
  releases on its way out.
  """
  @spec release(GenServer.server()) :: :ok
  def release(server \\ @name) do
    GenServer.call(server, {:release, self()}, @release_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The `Retry-After` this semaphore would put on a rejection right now.

  `request/1` already carries one on the rejection it returns. This is for the
  caller that got as far as *queueing* and then gave up waiting: the same "come
  back later", with the same estimate behind it, but no rejection to read it
  off.
  """
  @spec retry_after(GenServer.server()) :: retry_after()
  def retry_after(server \\ @name) do
    GenServer.call(server, :retry_after)
  catch
    # A request answering a client must not fail because the semaphore is
    # momentarily unreachable. The header is a hint, and one second is the
    # floor the estimate is clamped to anyway.
    :exit, _reason -> 1
  end

  @doc """
  Current occupancy and the limits it is measured against.

  For tests and for `AudioProxy.Readiness`; nothing on the render path reads it.

  `timeout` is exposed because the readiness probe has a budget an orchestrator
  set — a probe that waits the default five seconds for a wedged semaphore has
  already failed, whatever it eventually answers. Callers with no deadline of
  their own should leave it alone.
  """
  @spec stats(GenServer.server(), timeout()) :: stats()
  def stats(server \\ @name, timeout \\ 5_000) do
    GenServer.call(server, :stats, timeout)
  end

  ## Server

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       capacity: Keyword.get(opts, :capacity),
       queue_size: Keyword.get(opts, :queue_size)
     }}
  end

  @impl true
  def handle_call({:request, pid, class}, _from, state) do
    cond do
      Map.has_key?(state.held, pid) ->
        {:reply, {:error, :already_held}, state}

      # A second request from a process already waiting would put it in the
      # queue twice and let it be granted twice.
      Map.has_key?(state.waiters, pid) ->
        {:reply, {:error, :already_held}, state}

      map_size(state.held) < capacity(state) ->
        {:reply, :granted, hold(state, pid, Process.monitor(pid), 0, class)}

      map_size(state.waiters) < queue_size(state) ->
        {:reply, :queued, enqueue(state, pid, class)}

      # Full. Either this arrival outranks something displaceable, or it is
      # refused exactly as it was before classes existed.
      victim = victim(state, class) ->
        {:reply, :queued, state |> displace(victim) |> enqueue(pid, class)}

      true ->
        {retry_after, state} = reject(state, class)
        {:reply, {:error, {:queue_full, retry_after}}, state}
    end
  end

  def handle_call({:release, pid}, _from, state) do
    {:reply, :ok, forget(state, pid)}
  end

  def handle_call(:retry_after, _from, state) do
    {:reply, estimate(state), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       held: map_size(state.held),
       queued: map_size(state.waiters),
       capacity: capacity(state),
       queue_size: queue_size(state)
     }, state}
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {:noreply, forget(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Slots

  defp hold(state, pid, monitor, waited, class) do
    slot = %{monitor: monitor, started_at: System.monotonic_time(), class: class}

    state = %{state | held: Map.put(state.held, pid, slot)}

    emit(state, :acquired, %{wait: waited}, class)
  end

  defp enqueue(state, pid, class) do
    waiter = %{monitor: Process.monitor(pid), queued_at: System.monotonic_time(), class: class}

    state = %{
      state
      | waiters: Map.put(state.waiters, pid, waiter),
        order: Map.update!(state.order, class, &:queue.in(pid, &1))
    }

    emit(state, :queued, %{}, class)
  end

  defp reject(state, class) do
    retry_after = estimate(state)

    {retry_after, emit(state, :rejected, %{retry_after: retry_after}, class)}
  end

  # The lowest-class waiter this arrival outranks, newest first, or `nil` if it
  # outranks nothing queued. `@evictable` is scanned back to front — lowest
  # class first — and `interactive` is not in it, so no amount of rank
  # arithmetic can reach a listener.
  defp victim(state, class) do
    @evictable
    |> Enum.reverse()
    |> Enum.take_while(&(&1 != class))
    |> Enum.find_value(fn candidate ->
      case :queue.out_r(state.order[candidate]) do
        {{:value, pid}, rest} -> {candidate, pid, rest}
        {:empty, _rest} -> nil
      end
    end)
  end

  # Drops the displaced waiter and tells it so. The reply is distinct from
  # queue-full because the two are distinguishable to the caller — it *was*
  # waiting, and something outranked it — even though both mean "come back".
  defp displace(state, {class, pid, rest}) do
    {waiter, waiters} = Map.pop!(state.waiters, pid)
    Process.demonitor(waiter.monitor, [:flush])

    state = %{state | waiters: waiters, order: Map.put(state.order, class, rest)}
    retry_after = estimate(state)

    send(pid, {__MODULE__, {:displaced, retry_after}})

    emit(state, :displaced, %{retry_after: retry_after}, class)
  end

  # One function for every way a process stops mattering to this module —
  # `release/1`, a `DOWN`, or a caller that timed out — so that the holder and
  # waiter cases cannot drift apart. Unknown pids are `:ok` by omission, which
  # is what makes releasing twice harmless.
  defp forget(state, pid) do
    cond do
      slot = Map.get(state.held, pid) ->
        Process.demonitor(slot.monitor, [:flush])
        held = Map.delete(state.held, pid)
        duration = System.monotonic_time() - slot.started_at

        %{state | held: held, samples: sample(state.samples, duration)}
        |> emit(:released, %{duration: duration}, slot.class)
        |> grant_next()

      waiter = Map.get(state.waiters, pid) ->
        Process.demonitor(waiter.monitor, [:flush])

        # Deleted from `order` too, not left as a tombstone to be skipped on the
        # next grant. Tombstones are only consumed by a grant, so a saturated
        # semaphore whose waiters all give up accumulates them without bound —
        # measured at 200 dead entries for 200 abandoned waiters — and
        # `AP_QUEUE_SIZE` stops bounding what the queue costs. `:queue.delete/2`
        # is O(length), but length is now exactly `map_size(waiters)` and so at
        # most `AP_QUEUE_SIZE`, on a path that runs once per abandonment.
        %{
          state
          | waiters: Map.delete(state.waiters, pid),
            order: Map.update!(state.order, waiter.class, &:queue.delete(pid, &1))
        }
        |> emit(:abandoned, %{}, waiter.class)

      true ->
        state
    end
  end

  # Grants as many waiters as the freed capacity allows. Normally one — a single
  # release frees a single slot — but capacity is read from config, so a raised
  # `AP_MAX_CONCURRENCY` must not leave waiters parked behind a limit that no
  # longer applies.
  defp grant_next(state) do
    if map_size(state.held) < capacity(state) do
      case next_waiter(state) do
        {nil, state} ->
          state

        {{pid, waiter}, state} ->
          send(pid, {__MODULE__, :granted})

          state
          |> hold(pid, waiter.monitor, System.monotonic_time() - waiter.queued_at, waiter.class)
          |> grant_next()
      end
    else
      state
    end
  end

  # Pops the oldest waiter of the highest non-empty class. `order` and
  # `waiters` hold exactly the same pids — `enqueue/3` adds to both, `forget/2`
  # and `displace/2` remove from both — so a pid in a queue is always still
  # waiting, and `Map.pop!/2` asserts that rather than papering over a drift
  # between the two.
  defp next_waiter(state), do: next_waiter(state, @classes)

  defp next_waiter(state, []), do: {nil, state}

  defp next_waiter(state, [class | lower]) do
    case :queue.out(state.order[class]) do
      {:empty, _rest} ->
        next_waiter(state, lower)

      {{:value, pid}, rest} ->
        {waiter, waiters} = Map.pop!(state.waiters, pid)

        {{pid, waiter}, %{state | order: Map.put(state.order, class, rest), waiters: waiters}}
    end
  end

  ## Retry-After

  defp sample(samples, duration), do: Enum.take([duration | samples], @samples)

  defp estimate(state) do
    depth = map_size(state.waiters)
    capacity = capacity(state)

    # `depth + 1` counts the caller being rejected: it is being told when to come
    # back, and everyone already queued is in front of it.
    estimate = average_hold_ms(state) * (depth + 1) / capacity / 1_000

    estimate |> ceil() |> max(1) |> min(Config.get(:render_timeout))
  end

  defp average_hold_ms(%__MODULE__{samples: []}), do: @default_hold_ms

  defp average_hold_ms(%__MODULE__{samples: samples}) do
    native = Enum.sum(samples) / length(samples)

    System.convert_time_unit(trunc(native), :native, :millisecond)
  end

  ## Telemetry

  defp emit(state, event, measurements, class) do
    occupancy =
      Map.merge(depths(state), %{
        held: map_size(state.held),
        queued: map_size(state.waiters)
      })

    :telemetry.execute(
      @telemetry ++ [event],
      Map.merge(measurements, occupancy),
      %{capacity: capacity(state), queue_size: queue_size(state), class: class}
    )

    state
  end

  # `:queue.len/1` is O(length) and this runs on every event, but every queue is
  # bounded by `AP_QUEUE_SIZE` and their lengths sum to `map_size(waiters)` —
  # so this is the same walk the module already pays for an abandonment, once
  # per event rather than once per waiter.
  defp depths(state) do
    Map.new(@classes, fn class -> {:"queued_#{class}", :queue.len(state.order[class])} end)
  end

  ## Limits

  defp capacity(%__MODULE__{capacity: nil}), do: Config.get(:max_concurrency)
  defp capacity(%__MODULE__{capacity: capacity}), do: capacity

  defp queue_size(%__MODULE__{queue_size: nil}), do: Config.get(:queue_size)
  defp queue_size(%__MODULE__{queue_size: queue_size}), do: queue_size
end
