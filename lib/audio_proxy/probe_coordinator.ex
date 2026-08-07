defmodule AudioProxy.ProbeCoordinator do
  @moduledoc """
  One `ffprobe` per in-flight source, shared by everyone who asks about it.

  The single-flight in front of `AudioProxy.Ffprobe.probe/2`, in the shape
  `AudioProxy.RenderCoordinator` already uses for renders: a `Registry` of
  unique identities, a coordinator process per identity, a `DynamicSupervisor`
  holding them, and a broadcast to everyone waiting.

  Without it, N concurrent requests for one variant spawn N probes and exactly
  one render — the registry that exists to stop duplicate work sits *behind* the
  gate that now does some. Worse for the case the audio-only policy is about: N
  concurrent requests for a *refused* source spawn N probes and no render at
  all, so the render queue, which is what sheds load, never sees them.

  ## The identity is the source, not the cache key

  This is the one place this module departs from the render coordinator, and it
  is deliberate. A render is identified by its cache key, because the bytes it
  produces depend on every option in the URL. A probe reads container headers,
  and what it finds depends on the *source* and nothing else — `f:mp3/br:128`
  and `f:opus` of one file ask ffprobe the identical question about the
  identical bytes.

  So the key is `AudioProxy.Source.canonical/1`, which buys two things a
  cache-key identity would not:

    * concurrent requests for *different variants* of one source share a probe,
      which is the common shape when a client is fetching several renditions;
    * `/info` shares the mechanism with the render gate, as it must, since
      `/info` has no variant and therefore no cache key to be identified by.

  The staleness window is unchanged either way: it is one probe's lifetime, and
  the render that follows reads the same bytes the probe did.

  ## Asking

  `probe/3` either starts the probe or attaches to the running one, and returns
  exactly what `AudioProxy.Ffprobe.probe/2` would have returned — `{:ok,
  decoded_json}` or `{:error, reason}` in that module's own vocabulary. A caller
  that already handled `probe/2` needs no new clause.

  A caller cannot tell whether it started the probe or joined one, and has no
  reason to: it is waiting for a verdict either way.

  ## The start race

  Starting and joining are the same call, as in `AudioProxy.RenderCoordinator`:
  `DynamicSupervisor.start_child/2` either succeeds — this caller spawned the
  probe, and its pid was in the waiter list before `init/1` returned, so no
  verdict can be broadcast before it is listening — or answers
  `{:error, {:already_started, pid}}`, which is a join. Losing the race to a
  coordinator that is stopping is a caught exit and a retry, which starts a
  fresh probe.

  ## The probe runs beside the coordinator, not inside it

  `Ffprobe.probe/2` blocks: it spawns the subprocess with itself as consumer and
  collects chunks until the output ends. A GenServer cannot do that and still
  answer the joins that are coalescing onto it — the same reason
  `AudioProxy.RenderCoordinator` asks the semaphore with `request/1` rather than
  `acquire/1`.

  So the coordinator spawns a monitored runner process which calls
  `Ffprobe.probe/2` and sends the result back. The runner owns the subprocess,
  which means the kill discipline and `AP_PROBE_TIMEOUT` are unchanged and still
  live in one place. A runner that dies without reporting is a `DOWN`, and every
  waiter is told `:probe_failed` — a probe that produced no verdict is not a
  verdict.

  ## Teardown

  Two ways this ends, and they differ in what happens to the identity:

    * **A verdict** — broadcast, then the coordinator lingers briefly, still
      registered, so a request arriving a moment later is answered from it
      without a second spawn. The slot is already back.
    * **A failure** — broadcast to every waiter, then the identity is
      unregistered *immediately*, so the next request probes again rather than
      attaching to a corpse. Same discipline the render coordinator uses, and
      the same reason: a failed probe is not a cached "no".

  Waiters are deliberately *not* monitored, which is where this diverges from
  the render coordinator's lifecycle. There, the last subscriber leaving must
  cancel a subprocess that could otherwise run for minutes; here the runner is
  bounded by `AP_PROBE_TIMEOUT` and finishes in tens of milliseconds, so a
  monitor per waiter would buy a lifecycle to maintain and at most a few
  milliseconds of a slot. Sending a verdict to a pid that has since exited is
  harmless.
  """

  use GenServer

  require Logger

  alias AudioProxy.Ffprobe

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  # How long a coordinator holds a verdict after broadcasting it. Long enough
  # to catch a request that was already in flight, short enough that this is
  # in-flight sharing rather than the cross-request cache the proposal left out
  # of scope. A straggler that misses it probes again — wasteful, never wrong.
  @linger 1_000

  # Joining is a message to a live process that does no I/O in the callback, so
  # this only ever expires on a coordinator that is wedged.
  @join_timeout 5_000

  # Added to the probe timeout for a waiter's own deadline, so the runner's
  # timer — which classifies — always fires first. Wider than
  # `AudioProxy.Ffprobe`'s own margin because there is one more hop: the
  # runner's deadline is already probe timeout plus a margin, and this has to
  # sit outside that.
  @deadline_margin 3_000

  # Retries of the whole start-or-join loop. Only a coordinator stopping in the
  # window between the registry lookup and the join costs an attempt.
  @attempts 5

  @typedoc "Why a probe produced no verdict. `AudioProxy.Ffprobe`'s, plus a full pool."
  @type error_reason :: Ffprobe.error_reason()

  defstruct [:identity, :input, :opts, :runner, :result, waiters: MapSet.new()]

  @doc """
  The registry and supervisor this module needs, for the application tree.

  Start them after `AudioProxy.Ffmpeg.RenderSupervisor`: a coordinator spawns a
  runner that starts a subprocess through it, and reverse-order shutdown then
  tears the coordinators down first.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  @doc """
  Probes `input`, or joins the probe already running for `identity`.

  `identity` is what two callers must agree on to share a probe —
  `AudioProxy.Source.canonical/1`, per *The identity is the source* above.
  `input` and `opts` are `AudioProxy.Ffprobe.probe/2`'s, and are used only by
  the caller that turns out to be starting the probe: a joiner's are ignored,
  because the probe it is joining has already been spawned. That matters in
  exactly one place — a test whose two callers pass different `:executable`
  stand-ins for one source get whichever spawned first — and nowhere in
  production, where both are derived from the resolved source.
  """
  @spec probe(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def probe(identity, input, opts) when is_binary(identity) and is_binary(input) do
    case start_or_join(identity, input, opts, @attempts) do
      {:held, result} -> result
      {:pending, pid} -> await(pid, deadline(opts))
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_or_join(_identity, _input, _opts, 0) do
    Logger.error("probe coordinator kept stopping between lookup and join")

    {:error, :probe_failed}
  end

  defp start_or_join(identity, input, opts, attempts) do
    child = {__MODULE__, identity: identity, input: input, opts: opts, waiter: self()}

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} ->
        {:pending, pid}

      {:error, {:already_started, pid}} ->
        case join(pid) do
          :pending -> {:pending, pid}
          {:held, result} -> {:held, result}
          :gone -> start_or_join(identity, input, opts, attempts - 1)
        end

      # `init/1` refuses a slot it could not get as a `:shutdown` stop, so a
      # full pool is an error tuple rather than a crash report per request.
      {:error, {:shutdown, reason}} ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("could not start probe coordinator: #{inspect(reason)}")
        {:error, :probe_failed}
    end
  end

  defp join(pid) do
    GenServer.call(pid, {:join, self()}, @join_timeout)
  catch
    # Stopping between the registry lookup and this call. Retrying probes
    # afresh, which is correct — the identity is on its way out.
    :exit, _reason -> :gone
  end

  # Monitored rather than trusted to answer: a coordinator killed by its
  # supervisor never broadcasts, and a waiter with only a deadline would hold
  # the request for the whole probe timeout to learn it.
  #
  # The monitor is set up after the join, which is not a race — a verdict sent
  # before the monitor exists is already in this mailbox, and `receive` scans in
  # arrival order, so it is selected ahead of the `DOWN` that follows it.
  defp await(pid, deadline) do
    monitor = Process.monitor(pid)

    receive do
      {__MODULE__, ^pid, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Logger.error("probe coordinator died without reporting: #{inspect(reason)}")
        {:error, :probe_failed}
    after
      deadline ->
        Process.demonitor(monitor, [:flush])
        drain(pid)
        {:error, :probe_timeout}
    end
  end

  # This runs in Bandit's connection process, which is reused for the next
  # request on a keep-alive connection, so a verdict that arrived just after the
  # deadline must not be left to accumulate. Unlike the render path's drain
  # there is no barrier to make it exact: nothing here can stop the coordinator,
  # so a verdict still in flight is missed. It would never match again anyway —
  # the pid is in the pattern — and the next drain on this connection collects
  # it.
  defp drain(pid) do
    receive do
      {__MODULE__, ^pid, _result} -> drain(pid)
    after
      0 -> :ok
    end
  end

  defp deadline(opts), do: Ffprobe.timeout(opts) + @deadline_margin

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Never restarted, for the same reason a render coordinator is not: every
      # waiter has already been told, and a fresh request will probe again.
      restart: :temporary,
      shutdown: 6_000
    }
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :identity)))
  end

  defp via(identity), do: {:via, Registry, {@registry, identity}}

  ## Server

  @impl true
  def init(opts) do
    # So that a supervisor shutdown arrives as an `{:EXIT, _, _}` this process
    # handles rather than a silent kill, which is what takes the runner — and
    # its `ffprobe` — down with it.
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      identity: Keyword.fetch!(opts, :identity),
      input: Keyword.fetch!(opts, :input),
      opts: Keyword.fetch!(opts, :opts),
      # Registered before the runner exists, so the caller that started this
      # probe cannot miss the verdict.
      waiters: MapSet.new([Keyword.fetch!(opts, :waiter)])
    }

    {:ok, spawn_runner(state)}
  end

  # The runner calls `Ffprobe.probe/2` and reports. It has to be a separate
  # process because that call blocks — see *The probe runs beside the
  # coordinator* in the moduledoc — and it must be the one that calls, not this
  # one, because `probe/2` spawns the subprocess with `consumer: self()`.
  #
  # Linked rather than monitored, and this process traps exits, so one construct
  # covers both directions. A runner that crashes is an `{:EXIT, _, reason}`
  # here, which is the failure path; a coordinator killed by its supervisor
  # takes the runner with it, and the runner's death takes the `ffprobe` with
  # *that* — the pipeline monitors its consumer. A monitor alone would have left
  # a probe running for its whole timeout after the thing that wanted it was
  # gone.
  defp spawn_runner(state) do
    coordinator = self()
    %{input: input, opts: opts} = state

    runner = spawn_link(fn -> send(coordinator, {:probe_result, Ffprobe.probe(input, opts)}) end)

    %{state | runner: runner}
  end

  @impl true
  def handle_call({:join, pid}, _from, %__MODULE__{result: nil} = state) do
    {:reply, :pending, %{state | waiters: MapSet.put(state.waiters, pid)}}
  end

  # The verdict is already in, so this joiner is answered from the reply itself
  # and never needs a broadcast.
  def handle_call({:join, _pid}, _from, state) do
    {:reply, {:held, state.result}, state}
  end

  @impl true
  def handle_info({:probe_result, result}, %__MODULE__{result: nil} = state) do
    state = %{state | result: result}

    case result do
      {:ok, _probe} ->
        broadcast(state, result)
        Process.send_after(self(), :linger_expired, @linger)
        {:noreply, state}

      {:error, _reason} ->
        fail(state, result)
    end
  end

  # The runner is gone. Whether that is expected turns on the verdict rather
  # than on the exit reason: a runner that reported exits `:normal` immediately
  # afterwards, and messages between two processes keep their order, so a
  # verdict that exists was always delivered before this. A runner that is gone
  # *without* one produced nothing, whatever it exited with, and a probe with no
  # verdict is not a verdict — every waiter is told so, and the identity goes.
  def handle_info({:EXIT, runner, reason}, %__MODULE__{runner: runner} = state) do
    if state.result do
      {:noreply, %{state | runner: nil}}
    else
      Logger.error("probe runner died before reporting: #{inspect(reason)}")

      fail(%{state | runner: nil}, {:error, :probe_failed})
    end
  end

  def handle_info(:linger_expired, state), do: {:stop, :normal, state}

  # The other link is the supervisor's, so this is the shutdown path.
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  # The identity goes *first*, then everyone waiting is told. Both orders stop
  # a joiner from being handed a failed verdict — a call that arrives after
  # `{:stop, :normal, _}` is returned gets an exit, which `join/1` reads as
  # `:gone` and retries — but only this one closes the window in which a waiter
  # has its answer and the registry still lists the coordinator. A caller that
  # acts on the failure the instant it arrives (a test, or a retry loop) would
  # otherwise find an entry that is on its way out and take the slow path
  # through the retry rather than simply probing again.
  defp fail(state, result) do
    Registry.unregister(@registry, state.identity)

    broadcast(state, result)

    {:stop, :normal, state}
  end

  defp broadcast(state, result) do
    Enum.each(state.waiters, fn pid -> send(pid, {__MODULE__, self(), result}) end)
  end
end
