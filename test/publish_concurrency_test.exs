defmodule AudioProxy.PublishConcurrencyTest do
  @moduledoc """
  The `concurrency:` group that serializes publishing, against the jobs
  `.github/workflows/ci.yml` actually declares.

  A moving tag — `:edge` on every push to `main`, `:latest` and `:X.Y` on a
  release — is shared state that no `needs:` edge protects. Two pushes landing
  close together run two whole pipelines, each stitching its own per-arch
  digests onto those tags, and without a group the tag names whichever pipeline
  finished last rather than the newer commit. The immutable `:sha-<12>` tags are
  unaffected: they name their own commit.

  `publish` is the only job that writes a tag, so it is the only job in the
  group — and **the exclusivity is the invariant this file exists to hold.**
  GitHub allows exactly one *pending* job per concurrency group and cancels the
  previously pending one whenever another is queued; `cancel-in-progress: false`
  protects a job that is already running and does nothing for a queued one. So a
  second grouped job gives one run two ways to want the group at once — a matrix
  leg and its sibling, or `meta` and `verify-published` — and the eviction that
  follows lands on whatever is pending, up to and including a *newer* run's
  `meta`, whose cancellation skips that run's whole publish half and leaves the
  moving tag on the older commit. That is the bug the group exists to fix,
  turned deterministic. A well-meant edit that adds `verify-published` "so the
  verification is serialized too", or that grafts the group onto `meta`, is
  therefore not a tightening but a regression, and it is the edit this guard is
  aimed at.

  Two properties of the group itself are also asserted, because both are
  plausible tidy-ups with no visible symptom until two pushes collide.
  `cancel-in-progress` must stay `false`: `true` is the reflex everywhere else
  and here it would let a new push kill a run midway through `imagetools create`,
  leaving some tags of a release stitched and others not — the partial state the
  digest-then-stitch split exists to prevent. And the key must stay
  `github.ref`, so `main` and each release tag queue separately over their
  disjoint tag sets.

  Two things this deliberately does not assert. That GitHub honours the key —
  that is GitHub's behaviour, and what is ours is the workflow declaring it. And
  that publishing happens in *commit order*: it does not, because GitHub queues
  by arrival at the job, so a run whose build was slow can publish after a newer
  one. Serialization prevents a torn manifest, not a stale tag.
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
    # The exclusivity above is only correct while `publish` really is the sole
    # writer. `image-build` pushes by digest and names nothing; if a second job
    # grows an `imagetools create` or a `--tag`, the group is in the wrong place
    # and every message in this file is misleading.
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
