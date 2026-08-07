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
    * `:queued` — the caller is in the FIFO queue and will receive
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

  `held` and `queued` are the occupancy and depth *after* the event; `wait` and
  `duration` are native time units. Metadata is always `%{capacity:,
  queue_size:}`. `:abandoned` is one more event than `design.md` listed, and it
  is here so that a queue draining by attrition — clients giving up — does not
  leave `queued` reading high until the next unrelated event.

  `AudioProxy.Metrics` counts `:rejected` from this set and takes its occupancy
  gauges from `stats/2` instead, so the accuracy of what it publishes does not
  depend on every event being seen.
  """

  use GenServer

  alias AudioProxy.Config

  @name __MODULE__

  @telemetry [:audio_proxy, :semaphore]

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

  @typedoc "What `request/1` answers. See the moduledoc."
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
    order: :queue.new(),
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
    Enum.map([:acquired, :queued, :rejected, :released, :abandoned], &(@telemetry ++ [&1]))
  end

  @doc """
  Asks for a slot for the calling process, answering immediately.

  See the moduledoc for the three outcomes. A `:queued` caller receives
  `{AudioProxy.Semaphore, :granted}` when a slot comes free, and must then treat
  itself as a holder — including releasing it.
  """
  @spec request(GenServer.server()) :: outcome()
  def request(server \\ @name) do
    GenServer.call(server, {:request, self()})
  end

  @doc """
  Takes a slot for the calling process, waiting for one if the queue has room.

  Returns `:ok`, `{:error, {:queue_full, retry_after}}` when there was no room
  to wait, `{:error, :timeout}` when `:timeout` elapsed first, or
  `{:error, :already_held}`. Options:

    * `:timeout` — how long to wait for a queued slot. Defaults to `:infinity`,
      because the thing that bounds a render is `AP_RENDER_TIMEOUT` and a
      shorter wait here would only turn a queued request into a failed one.
    * `:server` — which semaphore, for tests running their own.

  A timeout releases whatever the race may have granted, so it does not leak a
  slot; see *The caller-timeout race* in the moduledoc, and `release/1` for the
  one case that release cannot cover.
  """
  @spec acquire(keyword()) :: :ok | {:error, term()}
  def acquire(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    timeout = Keyword.get(opts, :timeout, :infinity)

    case request(server) do
      :granted -> :ok
      :queued -> await_grant(server, timeout)
      {:error, _reason} = error -> error
    end
  end

  defp await_grant(server, timeout) do
    receive do
      {__MODULE__, :granted} -> :ok
    after
      timeout ->
        release(server)

        # `release/1` is a call, so the server has already handled it and
        # anything it sent is in this mailbox. Nothing can arrive later.
        receive do
          {__MODULE__, :granted} -> :ok
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
  def handle_call({:request, pid}, _from, state) do
    cond do
      Map.has_key?(state.held, pid) ->
        {:reply, {:error, :already_held}, state}

      # A second request from a process already waiting would put it in the
      # queue twice and let it be granted twice.
      Map.has_key?(state.waiters, pid) ->
        {:reply, {:error, :already_held}, state}

      map_size(state.held) < capacity(state) ->
        {:reply, :granted, hold(state, pid, Process.monitor(pid), 0)}

      map_size(state.waiters) >= queue_size(state) ->
        {retry_after, state} = reject(state)
        {:reply, {:error, {:queue_full, retry_after}}, state}

      true ->
        {:reply, :queued, enqueue(state, pid)}
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

  defp hold(state, pid, monitor, waited) do
    state = %{
      state
      | held: Map.put(state.held, pid, %{monitor: monitor, started_at: System.monotonic_time()})
    }

    emit(state, :acquired, %{wait: waited})
  end

  defp enqueue(state, pid) do
    waiter = %{monitor: Process.monitor(pid), queued_at: System.monotonic_time()}

    state = %{
      state
      | waiters: Map.put(state.waiters, pid, waiter),
        order: :queue.in(pid, state.order)
    }

    emit(state, :queued, %{})
  end

  defp reject(state) do
    retry_after = estimate(state)

    {retry_after, emit(state, :rejected, %{retry_after: retry_after})}
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
        |> emit(:released, %{duration: duration})
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
            order: :queue.delete(pid, state.order)
        }
        |> emit(:abandoned, %{})

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
          |> hold(pid, waiter.monitor, System.monotonic_time() - waiter.queued_at)
          |> grant_next()
      end
    else
      state
    end
  end

  # Pops the oldest waiter. `order` and `waiters` hold exactly the same pids —
  # `enqueue/2` adds to both and `forget/2` removes from both — so a pid in the
  # queue is always still waiting, and `Map.pop!/2` asserts that rather than
  # papering over a drift between the two.
  defp next_waiter(state) do
    case :queue.out(state.order) do
      {:empty, order} ->
        {nil, %{state | order: order}}

      {{:value, pid}, order} ->
        {waiter, waiters} = Map.pop!(state.waiters, pid)

        {{pid, waiter}, %{state | order: order, waiters: waiters}}
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

  defp emit(state, event, measurements) do
    :telemetry.execute(
      @telemetry ++ [event],
      Map.merge(measurements, %{held: map_size(state.held), queued: map_size(state.waiters)}),
      %{capacity: capacity(state), queue_size: queue_size(state)}
    )

    state
  end

  ## Limits

  defp capacity(%__MODULE__{capacity: nil}), do: Config.get(:max_concurrency)
  defp capacity(%__MODULE__{capacity: capacity}), do: capacity

  defp queue_size(%__MODULE__{queue_size: nil}), do: Config.get(:queue_size)
  defp queue_size(%__MODULE__{queue_size: queue_size}), do: queue_size
end
