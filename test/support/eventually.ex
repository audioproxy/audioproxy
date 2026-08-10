defmodule AudioProxy.Eventually do
  @moduledoc """
  The suite's one poll loop: wait for a condition that becomes true without
  sending a message when it does.

  `assert_receive` covers everything that *does* send a message, and is the
  better tool whenever it applies. This module is for the rest — a supervisor's
  child list emptying, a variant landing in the store, an OS process exiting —
  where the only way to know is to look again.

  ## Two waits, because there are two contracts

  `wait_until/2` flunks when its deadline expires; `eventually?/2` returns
  `false`. That is the one distinction in here worth reading twice, and the
  names carry it so a call site does not have to:

    * `wait_until/2` is for a **precondition** — something that must become
      true for the rest of the test to mean anything. Expiry is a broken test,
      so it fails on the spot, at the wait, rather than three assertions later
      with a confusing message.
    * `eventually?/2` is for a wait that **is** the assertion, including the
      negative one (`refute eventually?(...)`). Its caller wants the answer,
      not a failure.

  Before this module the two lived in seventeen files under four names
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
    poll(condition, System.monotonic_time(:millisecond) + deadline)
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
  """
  @spec alive?(integer()) :: boolean()
  def alive?(os_pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  defp poll(condition, expiry) do
    cond do
      condition.() ->
        true

      System.monotonic_time(:millisecond) >= expiry ->
        false

      true ->
        Process.sleep(@interval)
        poll(condition, expiry)
    end
  end
end
