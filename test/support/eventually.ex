defmodule AudioProxy.Eventually do
  @moduledoc """
  The suite's one poll loop: wait for a condition that becomes true without
  sending a message when it does.

  `assert_receive` covers everything that *does* send a message, and is the
  better tool whenever it applies. This module is for the rest — a supervisor's
  child list emptying, a variant landing in the store, an OS process exiting —
  where the only way to know is to look again.

  ## Three waits, because there are three contracts

  `wait_until/2` flunks when its deadline expires; `eventually?/2` returns
  `false`; `wait_for/2` hands back what it waited for. That is the one
  distinction in here worth reading twice, and the names carry it so a call
  site does not have to:

    * `wait_until/2` is for a **precondition** — something that must become
      true for the rest of the test to mean anything. Expiry is a broken test,
      so it fails on the spot, at the wait, rather than three assertions later
      with a confusing message.
    * `eventually?/2` is for a wait that **is** the assertion, including the
      negative one (`refute eventually?(...)`). Its caller wants the answer,
      not a failure.
    * `wait_for/2` is for a wait whose **result is a value** the test then
      asserts on — the scrape body that finally matched, the pid of the
      restarted process. Polling and then re-reading would reopen the race the
      poll exists to close, because the value can change again in between, so
      the wait carries out the one it observed.

  `wait_for/2`'s condition returns `{:ok, value}` or `{:retry, observed}`
  rather than something truthy, and the payload on the retry branch is the
  reason this is a third function rather than `eventually?/2` with a different
  return type. A scrape body that does not match yet is perfectly truthy, so
  truthiness cannot carry the verdict; and "the counter never reached X" is
  not a diagnostic without the last scrape printed beside it. `observed` is
  what the failure message prints, which is what makes a custom message
  parameter unnecessary.

  Before this module the first two lived in seventeen files under four names
  (`wait_until` in eleven, `eventually` in two, `await` in two, and the
  `gone_within?`/`alive?` pair in four) and were told apart only by which file
  you happened to be reading.

  ## The deadline is a parameter; the interval is not

  How long a condition is allowed to take is a property of the *test* — a
  probe-coordinator drain and a semaphore emptying have genuinely different
  budgets, from 2 s to 10 s across the suite — so the deadline stays an
  argument, visible where the test is read, with a modest 5 s default. A file
  whose budget is not 5 s passes its own at the call site.

  How *often* it is checked is a property of nothing. The copies polled at 5,
  10, 20, 25 and 50 ms, and no file had a reason for its number; six already
  used 10 ms, so 10 ms it is. Nothing in the suite asserts on how often a
  condition is checked, and a caller that ever needs its own interval should
  get one added here rather than reintroducing a local loop.

  The deadline is measured against the monotonic clock rather than by counting
  sleeps, so `"never held within 5000ms"` names the time that actually passed
  — including time spent evaluating a slow condition, which several of the
  old copies silently excluded.

  It is checked *between* evaluations, never during one, so a condition that
  blocks overruns the deadline by however long it blocks. That matters when
  the condition is a request rather than a peek: budget such a caller in
  conditions rather than in milliseconds, and say so where it is written.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @interval 10
  @deadline 5_000

  @doc """
  Polls `condition` until it returns truthy, or flunks when `deadline`
  (milliseconds) expires.

  For a condition that must hold. If you intend to assert on whether it held,
  use `eventually?/2`.
  """
  @spec wait_until((-> as_boolean(term())), non_neg_integer()) :: :ok
  def wait_until(condition, deadline \\ @deadline) do
    if eventually?(condition, deadline) do
      :ok
    else
      flunk("condition never held within #{deadline}ms")
    end
  end

  @doc """
  Polls `condition` until it returns truthy, and returns whether it did before
  `deadline` (milliseconds) expired.

  For a wait whose answer is the thing under test.
  """
  @spec eventually?((-> as_boolean(term())), non_neg_integer()) :: boolean()
  def eventually?(condition, deadline \\ @deadline) do
    match?({:ok, _}, poll(fn -> truthy(condition) end, deadline))
  end

  @doc """
  Polls `condition` until it returns `{:ok, value}`, returns that `value`, or
  flunks when `deadline` (milliseconds) expires.

  For a wait whose result is a value the test goes on to assert on. The retry
  branch returns `{:retry, observed}`, and `observed` is what the failure
  message prints — make it whatever identifies the fault.

      body =
        wait_for(fn ->
          %{body: body} = scrape()
          if body =~ expected, do: {:ok, body}, else: {:retry, body}
        end)
  """
  @spec wait_for((-> {:ok, value} | {:retry, term()}), non_neg_integer()) :: value
        when value: term()
  def wait_for(condition, deadline \\ @deadline) do
    case poll(condition, deadline) do
      {:ok, value} ->
        value

      {:expired, observed} ->
        flunk(
          "condition never returned {:ok, _} within #{deadline}ms; last observed:\n" <>
            describe(observed)
        )
    end
  end

  @doc """
  Whether the OS process `os_pid` exits within `deadline` milliseconds.

  A poll for `not alive?(os_pid)` and nothing more; it exists as its own
  function because `alive?/1` needs a home.
  """
  @spec gone_within?(integer(), non_neg_integer()) :: boolean()
  def gone_within?(os_pid, deadline \\ @deadline) do
    eventually?(fn -> not alive?(os_pid) end, deadline)
  end

  @doc """
  Whether the OS process `os_pid` still exists, via `kill -0`.

  An OS pid, not a BEAM pid — `Process.alive?/1` is the one for those. Used to
  prove the proxy leaves no orphaned ffmpeg behind.

  Delegates to `AudioProxy.OsProcess.alive?/1`: a process that exists but is
  not signalable, or a missing `kill` executable, is treated as alive, because
  the safe default is to keep waiting rather than declare the process gone.
  """
  @spec alive?(integer()) :: boolean()
  def alive?(os_pid), do: AudioProxy.OsProcess.alive?(os_pid)

  # The one loop, in the shape of the wait that carries the most: a verdict
  # plus a payload. `eventually?/2` reaches it through `truthy/1`, which is a
  # lossless narrowing — the two boolean waits simply throw the payload away —
  # so adding `wait_for/2` did not fork a second loop or a second interval.
  defp poll(condition, deadline) do
    poll_until(condition, System.monotonic_time(:millisecond) + deadline)
  end

  defp poll_until(condition, expiry) do
    case condition.() do
      {:ok, value} ->
        {:ok, value}

      {:retry, observed} ->
        if System.monotonic_time(:millisecond) >= expiry do
          {:expired, observed}
        else
          Process.sleep(@interval)
          poll_until(condition, expiry)
        end
    end
  end

  defp truthy(condition) do
    case condition.() do
      value when value in [nil, false] -> {:retry, value}
      value -> {:ok, value}
    end
  end

  # The last observation printed raw when it is text — `await_scrape`'s whole
  # diagnostic was a multi-line scrape body, and `inspect/1` would escape the
  # newlines out of it. Unbounded on that branch deliberately: the body *is*
  # the diagnostic, and a truncated exposition is the one that omits the line
  # you were looking for.
  #
  # `String.valid?/1` rather than `is_binary/1` alone, because a message
  # carrying invalid UTF-8 does not merely print badly: `:io.put_chars` raises
  # from inside `ExUnit.CLIFormatter`, which takes down the formatter and the
  # runner with it. A wait that expires would then kill the whole suite rather
  # than fail one test.
  defp describe(observed) when is_binary(observed) do
    if String.valid?(observed), do: observed, else: inspect(observed)
  end

  # Everything else at `inspect/2`'s default limit — a pid or a tuple prints
  # whole, and a term large enough to be truncated is one no reader wanted in
  # full.
  defp describe(observed), do: inspect(observed, pretty: true)
end
