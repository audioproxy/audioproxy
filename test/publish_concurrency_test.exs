defmodule AudioProxy.PublishConcurrencyTest do
  @moduledoc """
  The `concurrency:` group on `publish`, against what `ci.yml` declares.

  A moving tag is shared state no `needs:` edge protects, and `publish` is the
  only job that writes one.

  **The exclusivity is the invariant here.** A group holds one pending job and a
  new arrival evicts it, and `cancel-in-progress: false` protects only a job
  already running — so a second member lets one run evict a newer run's queued
  `meta` and strand the moving tag on the older commit, which is the bug the
  group exists to fix. An edit adding `verify-published` "so verification is
  serialized too" reads as a tightening, and is the edit this file is aimed at.

  Not asserted: that GitHub honours the key, and that publishing happens in
  commit order — it does not, since the queue is entered on arrival at the job.
  `docs/development.md` has the rest.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Workflow

  @serialized "publish"
  @group "publish-${{ github.ref }}"

  test "the job that writes the tags is serialized, on a ref-keyed group" do
    concurrency = concurrency(@serialized)

    assert concurrency != nil,
           """
           The job #{inspect(@serialized)} writes every moving tag and must carry:

               concurrency:
                 group: #{@group}
                 cancel-in-progress: false

           Without it, two pushes in flight at once can leave a moving tag on the
           older commit.
           """

    assert concurrency.group == @group,
           """
           #{inspect(@serialized)} is in the group #{inspect(concurrency.group)}, \
           not #{inspect(@group)}.

           The key must be `github.ref` so that `main` and a release tag queue
           separately — they touch disjoint tag sets and have no reason to wait
           on each other.
           """
  end

  test "a publish that has started is never cancelled" do
    assert concurrency(@serialized).cancel_in_progress == "false",
           """
           #{inspect(@serialized)} has cancel-in-progress \
           #{inspect(concurrency(@serialized).cancel_in_progress)}; it must be `false`.

           `true` is the usual idiom and is wrong here: cancelling a run
           mid-publish can leave some tags of a release stitched and others not.
           A publish that has begun finishes, and the next run supersedes it in
           order.
           """
  end

  test "no other job joins the group" do
    grouped =
      Workflow.jobs()
      |> Enum.filter(fn {_key, block} -> Workflow.concurrency(block) != nil end)
      |> Enum.map(fn {key, _block} -> key end)
      |> Enum.sort()

    assert grouped == [@serialized],
           """
           Exactly one job may declare a concurrency group, and it is \
           #{inspect(@serialized)}. These do: #{inspect(grouped)}

           GitHub allows one pending job per group and evicts the previously
           pending one when another is queued, so a second grouped job lets a run
           contend with itself and cancel a newer run's `meta` — the stale moving
           tag this group exists to prevent, made deterministic. If the intent
           was to serialize verification too, it cannot be done this way.
           """
  end

  test "the serialized job is the only one that moves a tag" do
    # The exclusivity argument holds only while `publish` is the sole writer.
    writers =
      Workflow.jobs()
      |> Enum.filter(fn {_key, block} ->
        steps = Workflow.uncommented(block)

        String.contains?(steps, "imagetools create") or Regex.match?(~r/^\s+--tag /m, steps)
      end)
      |> Enum.map(fn {key, _block} -> key end)
      |> Enum.sort()

    assert writers == [@serialized],
           """
           These jobs write image tags: #{inspect(writers)} — expected only \
           #{inspect(@serialized)}.

           The concurrency group is on `publish` because it is the sole writer of
           shared registry state. A second writer needs the group too, and two
           grouped jobs is the failure mode documented above, so this needs a
           rethink rather than another `concurrency:` block.
           """
  end

  defp concurrency(key) do
    jobs = Workflow.jobs()

    key |> Workflow.block!(jobs) |> Workflow.concurrency()
  end
end
