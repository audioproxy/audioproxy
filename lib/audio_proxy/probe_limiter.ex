defmodule AudioProxy.ProbeLimiter do
  @moduledoc """
  The probe budget: at most `AP_MAX_PROBE_CONCURRENCY` `ffprobe` processes at
  once, and no queue behind them.

  The second of this proxy's two subprocess pools, and deliberately not the
  first. `AudioProxy.Semaphore` rations *encoders* — a slot means a core is
  pinned for the length of a file — and putting probes under the same cap would
  queue a header read behind a transcode, which would make `/info`, the endpoint
  a client calls before it knows what to request, the slowest thing in the
  proxy. So: a counter of its own, and a probe never waits on a render slot.

  ## A ceiling, not a scheduler

  There is no wait queue, and that is the whole difference from
  `AudioProxy.Semaphore`. `acquire/0` either takes a slot or refuses; nobody
  ever waits for one. The measurements in
  `openspec/changes/archive/2026-08-07-bound-probe-concurrency/design.md`
  are the reason. A probe is about 45 ms of wall clock, some of it
  contended CPU, and the degradation past saturation is gradual — at 512 in
  flight a box holds a fifteenth of its file descriptors and a thirtieth of its
  process table while per-probe latency goes from 78 ms to six seconds. Nothing
  runs out; things just get slower.

  What that argues for is a bound whose job is to stop the tail, not to smooth
  the middle. Queueing here would buy a probe the right to wait for a resource
  it will hold for 45 ms, which is worth less than telling the client to come
  back — and a queue is where the property this module exists to protect (a
  probe never waits behind anything) would quietly come back.

  So overflow is `{:error, {:queue_full, retry_after}}`, which
  `AudioProxy.ErrorJSON` already renders as §5's 429 with `Retry-After`. The
  vocabulary is the semaphore's on purpose: a client cannot tell, and has no
  reason to care, which of the two pools was full.

  ## `Retry-After` is one second, and it is not an estimate

  The semaphore derives its estimate from how long recent renders held their
  slots, because a render is seconds-to-minutes long and the number carries
  information. A probe is 45 ms. Averaging those would produce a header that
  said "one second" after rounding to §5's floor no matter what was measured,
  by a route that implied otherwise. So it is a constant, said out loud here
  rather than computed to look like data.

  A saturated probe pool is also a transient in a way a saturated render pool is
  not: the slots turn over tens of times a second, so a client that comes back
  in a second is very likely to be admitted.

  ## One slot per process, released by exit if not by hand

  `AudioProxy.ProbeCoordinator` takes a slot in `init/1` and releases it the
  moment the probe reports, before its verdict-holding linger — the same
  discipline `AudioProxy.RenderCoordinator` follows with the semaphore, and for
  the same reason: what the linger keeps alive is a decoded map in memory, which
  costs no CPU and must not cost a slot.

  Holders are monitored, so a coordinator that crashes returns its slot when the
  `DOWN` fires and not later. `release/0` is therefore promptness rather than
  the guarantee, and is idempotent: releasing twice, or without holding, is
  `:ok`. Acquiring twice from one process is `{:error, :already_held}` — a
  coordinator runs one probe, and a second would be an accounting error.

  ## Configuration is read per operation

  `AP_MAX_PROBE_CONCURRENCY` is read from `AudioProxy.Config` on every
  `acquire/0` rather than in `init/1`, exactly as the semaphore reads its own
  limits, so `AudioProxy.ConfigHelper.put_config/1` takes effect in tests
  without restarting a supervised process. Tests wanting a limiter of their own
  pass `:name` and `:capacity` to `start_link/1`, which pins the limit and skips
  the config read.

  ## Events

  | Event | Measurements | When |
  |---|---|---|
  | `[:audio_proxy, :probe_limiter, :acquired]` | `held` | a probe slot was taken |
  | `[:audio_proxy, :probe_limiter, :rejected]` | `held`, `retry_after` | the ceiling was reached |
  | `[:audio_proxy, :probe_limiter, :released]` | `held`, `duration` | a holder gave its slot back |

  `held` is the occupancy *after* the event, so any one of them samples the
  gauge; `duration` is in native time units. Metadata is always
  `%{capacity: capacity}`. Deliberately parallel to the semaphore's events
  without being the same ones: an operator watching saturation needs to know
  *which* pool filled, and a shared event name with a tag would have made the
  two indistinguishable in any tool that aggregates by name.
  """

  use GenServer

  alias AudioProxy.Config

  @name __MODULE__

  @telemetry [:audio_proxy, :probe_limiter]

  # See the moduledoc: a constant, not an average. §5's floor is one second and
  # a probe pool turns over far faster than that.
  @retry_after 1

  # How long `release/0` may block before it leaves the slot to the monitor.
  # Every callback here is O(1), so reaching this means something is badly
  # wrong; it is a bound, not a budget.
  @release_timeout 5_000

  @typedoc "What `acquire/0` answers."
  @type outcome :: :ok | {:error, {:queue_full, pos_integer()}} | {:error, :already_held}

  @typedoc "Occupancy, for tests and for anyone asking rather than subscribing."
  @type stats :: %{held: non_neg_integer(), capacity: pos_integer()}

  defstruct [:capacity, held: %{}]

  @doc """
  Starts the limiter.

  Options, both optional:

    * `:name` — defaults to this module, which is what the application tree
      starts and what every other function defaults to.
    * `:capacity` — pins the limit instead of reading
      `AP_MAX_PROBE_CONCURRENCY` per operation. For tests that want a limiter
      of their own; production uses the config.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Takes a probe slot for the calling process, or refuses.

  Never waits. See the moduledoc for why there is no third outcome.
  """
  @spec acquire(GenServer.server()) :: outcome()
  def acquire(server \\ @name) do
    GenServer.call(server, {:acquire, self()})
  end

  @doc """
  Gives back the calling process' slot.

  Idempotent, and `:ok` even if the limiter is not running — a caller releasing
  from its own `terminate/2` during shutdown must not crash because the limiter
  stopped first. As with `AudioProxy.Semaphore.release/1`, `:ok` means "this
  caller is done with the slot" rather than "the limiter has processed that";
  what recovers a slot from a wedged limiter is the holder exiting.
  """
  @spec release(GenServer.server()) :: :ok
  def release(server \\ @name) do
    GenServer.call(server, {:release, self()}, @release_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The `Retry-After` a refused probe carries, in seconds.

  Public so that a caller which has to synthesise the same rejection — the
  render action's own deadline, say — reads it off here rather than inventing a
  second constant.
  """
  @spec retry_after() :: pos_integer()
  def retry_after, do: @retry_after

  @doc """
  How long `release/0` may block. Public for the same reason
  `AudioProxy.Semaphore.release_timeout/0` is: a caller that releases from its
  own `terminate/2` sizes its shutdown budget against this.
  """
  @spec release_timeout() :: pos_integer()
  def release_timeout, do: @release_timeout

  @doc """
  Current occupancy and the limit it is measured against. For tests; nothing on
  the request path reads it.
  """
  @spec stats(GenServer.server(), timeout()) :: stats()
  def stats(server \\ @name, timeout \\ 5_000) do
    GenServer.call(server, :stats, timeout)
  end

  ## Server

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{capacity: Keyword.get(opts, :capacity)}}
  end

  @impl true
  def handle_call({:acquire, pid}, _from, state) do
    cond do
      Map.has_key?(state.held, pid) ->
        {:reply, {:error, :already_held}, state}

      map_size(state.held) < capacity(state) ->
        held =
          Map.put(state.held, pid, %{
            monitor: Process.monitor(pid),
            started_at: System.monotonic_time()
          })

        {:reply, :ok, emit(%{state | held: held}, :acquired, %{})}

      true ->
        {:reply, {:error, {:queue_full, @retry_after}},
         emit(state, :rejected, %{retry_after: @retry_after})}
    end
  end

  def handle_call({:release, pid}, _from, state) do
    {:reply, :ok, forget(state, pid)}
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{held: map_size(state.held), capacity: capacity(state)}, state}
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {:noreply, forget(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One function for both ways a slot comes back, so `release/0` and a `DOWN`
  # cannot drift apart. An unknown pid is `:ok` by omission, which is what makes
  # releasing twice harmless.
  defp forget(state, pid) do
    case Map.pop(state.held, pid) do
      {nil, _held} ->
        state

      {slot, held} ->
        Process.demonitor(slot.monitor, [:flush])
        duration = System.monotonic_time() - slot.started_at

        emit(%{state | held: held}, :released, %{duration: duration})
    end
  end

  defp emit(state, event, measurements) do
    :telemetry.execute(
      @telemetry ++ [event],
      Map.put(measurements, :held, map_size(state.held)),
      %{capacity: capacity(state)}
    )

    state
  end

  defp capacity(%__MODULE__{capacity: nil}), do: Config.get(:max_probe_concurrency)
  defp capacity(%__MODULE__{capacity: capacity}), do: capacity
end
