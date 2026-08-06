defmodule AudioProxy.Readiness do
  @moduledoc """
  Whether this node should be sent new work — the state behind `GET /ready`.

  Readiness is routing advice, not health. `/health` answers "this VM is
  running"; `/ready` answers "give the next render to someone else". A node
  that is unready is still serving, still finishing what it has, and still
  answering `/health` 200 — an orchestrator that conflates the two restarts a
  container for being busy.

  ## Threshold and hysteresis

  The signal is the semaphore's wait-queue depth. The node trips to not-ready
  once depth reaches `AP_READY_QUEUE_THRESHOLD`, and recovers only once depth
  falls back to *half* of it or below:

      depth:      0   8   16  12  9   8   0
      threshold:  16              ↑ recover mark is 8
      ready?:     y   y   n   n   n   y   y

  Tracking instantaneous depth instead would flip the node on every sample
  while it hovered at the threshold — and a fleet under uniform load hovers
  together, so every node would flip together and the LB would be handed an
  empty pool. One flip per excursion is the whole point of the lower recovery
  mark; the mark is derived rather than configured because two knobs whose
  only valid relationship is "the second is smaller" is one knob and a
  validation rule.

  `AP_READY_QUEUE_THRESHOLD` of `0` disables the check: `/ready` is then a
  second liveness endpoint, always 200, which is what a single-node deployment
  wants.

  ## Failing toward ready

  A wrongly-unready fleet is an outage; a wrongly-ready node just queues. So
  every uncertainty here resolves to ready — an unreadable depth (a semaphore
  that is restarting, say) reads as `0`, and a `check/1` that cannot reach this
  server at all answers ready rather than raising into the probe.

  Both reads are bounded well inside a probe's own deadline, so "too slow"
  resolves the same way "unreachable" does rather than by making the
  orchestrator wait. What the fallback does *not* invent is the threshold: it
  reports the configured one, because `0` is the value that means the check is
  disabled and answering it here would misreport a broken latch as a
  switched-off one.

  ## State lives here, not in the probe

  The latch is a fact about the node, so two orchestrators polling `/ready`
  see the same answer rather than each carrying their own hysteresis. The
  transition happens on sampling — that is, when something asks — which is
  exactly when it can matter.
  """

  use GenServer

  alias AudioProxy.Config
  alias AudioProxy.Semaphore

  @name __MODULE__

  # A probe has a deadline its orchestrator set — Kubernetes' `timeoutSeconds`
  # defaults to one second — so waiting `GenServer.call/3`'s default five for a
  # wedged process would blow that budget whatever the answer turned out to be.
  # The depth read is the inner call and gets the tighter bound; the outer one
  # leaves the server room to make it and still answer.
  #
  # A caller that gives up is not a caller that stopped the work: the server
  # still finishes the sample and still advances the latch, so the *next* probe
  # sees a current verdict rather than a stale one.
  @depth_timeout 1_000
  @check_timeout 2_000

  @typedoc """
  What `check/1` answers.

  `queued` and `threshold` are the numbers the verdict was drawn from, carried
  so the endpoint can put them in its body — an operator debugging a probe
  wants the reading, not just the verdict.
  """
  @type verdict :: %{
          ready?: boolean(),
          queued: non_neg_integer(),
          threshold: non_neg_integer()
        }

  @doc """
  Starts the readiness latch.

  Options, all optional:

    * `:name` — defaults to this module, which is what the application tree
      starts and what `check/1` defaults to.
    * `:semaphore` — which semaphore to read depth from. For tests that run a
      semaphore of their own; production reads `AudioProxy.Semaphore`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Samples queue depth and answers whether this node should receive new work.

  Advances the hysteresis latch, so consecutive calls over a rising and
  falling excursion produce exactly one not-ready run.
  """
  @spec check(GenServer.server()) :: verdict()
  def check(server \\ @name) do
    GenServer.call(server, :check, @check_timeout)
  catch
    # Fail toward ready: an unreachable or too-slow latch must not eject a node
    # that is otherwise serving, and the supervisor is already restarting it.
    #
    # `threshold` is read from config rather than reported as `0`, even though
    # nothing sampled it. `0` is the value that *means* "readiness disabled",
    # so answering it here would tell an operator reading the body that someone
    # had switched the check off — the one explanation that is certainly wrong.
    # The configured number is the honest answer to "what would have tripped
    # this", and `Config.get/1` is a `:persistent_term` read that cannot fail
    # the way the call just did.
    :exit, _reason -> %{ready?: true, queued: 0, threshold: threshold()}
  end

  ## Server

  @impl true
  def init(opts) do
    {:ok,
     %{
       semaphore: Keyword.get(opts, :semaphore, Semaphore),
       tripped?: false
     }}
  end

  @impl true
  def handle_call(:check, _from, state) do
    threshold = threshold()
    queued = depth(state.semaphore)
    tripped? = latch(state.tripped?, queued, threshold)

    verdict = %{ready?: not tripped?, queued: queued, threshold: threshold}

    {:reply, verdict, %{state | tripped?: tripped?}}
  end

  # Disabled. Also clears a latch left over from a threshold that was set
  # before — there is no reconfiguration at runtime, but tests do it and the
  # honest reading of "disabled" is "always ready".
  defp latch(_tripped?, _queued, 0), do: false

  # Trip high...
  defp latch(false, queued, threshold), do: queued >= threshold

  # ...recover low. `div/2` floors, so a threshold of 1 recovers only at an
  # empty queue, which is the only depth below it.
  defp latch(true, queued, threshold), do: queued > div(threshold, 2)

  defp threshold, do: Config.get(:ready_queue_threshold)

  defp depth(semaphore) do
    Semaphore.stats(semaphore, @depth_timeout).queued
  catch
    :exit, _reason -> 0
  end
end
