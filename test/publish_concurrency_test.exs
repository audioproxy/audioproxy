defmodule AudioProxy.PublishConcurrencyTest do
  @moduledoc """
  The `concurrency:` group that serializes publishing, against the jobs
  `.github/workflows/ci.yml` actually declares.

  A moving tag — `:edge` on every push to `main`, `:latest` and `:X.Y` on a
  release — is shared state that no `needs:` edge protects. Two pushes landing
  close together run two whole pipelines, each stitching its own per-arch
  digests onto those tags, and without a group the tag names whichever pipeline
  finished last rather than the newer commit. The immutable `:sha-<12>` tags
  are unaffected: they name their own commit.

  The set is derived rather than listed. **A job that cannot run for a pull
  request is a publish-side job**, because the publish half is gated behind
  `meta`'s push-only `if:` and everything downstream of a skipped job is
  skipped too. So the guard asserts a biconditional: every push-only job is
  serialized, and no job that runs on a pull request is — verification jobs are
  pure functions of a commit, hold no registry state, and are the bulk of the
  wall clock, so serializing one would cost a busy day for nothing.

  Two things it cannot check, and both are why the group is written the way it
  is rather than left to review. `cancel-in-progress` must be `false`: the
  reflex everywhere else is `true`, and here it would let a new push kill a run
  mid-`publish` and leave some tags of a release stitched and others not —
  precisely the partial state the digest-then-stitch split exists to prevent.
  And the group must be keyed by `github.ref`, so `main` and each release tag
  get their own queue instead of waiting on each other over disjoint tag sets.
  A future edit that flips either is a plausible tidy-up with no visible
  symptom until two pushes collide, which is the definition of what a guard is
  for.

  What this does *not* assert is that GitHub honours the key. That is GitHub's
  behaviour, not ours; what is ours is the workflow declaring it.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Workflow

  @group "publish-${{ github.ref }}"

  test "every publish-side job is serialized, on one ref-keyed group" do
    for key <- publish_side() do
      concurrency = concurrency(key)

      assert concurrency != nil,
             """
             The job #{inspect(key)} never runs for a pull request, so it is part \
             of the publish half and must share the serializing group:

                 concurrency:
                   group: #{@group}
                   cancel-in-progress: false

             Without it, two pushes in flight at once can leave a moving tag on \
             the older commit.
             """

      assert concurrency.group == @group,
             """
             The job #{inspect(key)} is in the group #{inspect(concurrency.group)}, \
             not #{inspect(@group)}.

             Every publish-side job shares one group so the version `meta` \
             computes and the digests `publish` pushes come from the same point \
             in the queue, and the key is `github.ref` so `main` and a release \
             tag queue separately.
             """
    end
  end

  test "a publish that has started is never cancelled" do
    for key <- publish_side() do
      assert concurrency(key).cancel_in_progress == "false",
             """
             The job #{inspect(key)} has cancel-in-progress \
             #{inspect(concurrency(key).cancel_in_progress)}; it must be `false`.

             `true` is the usual idiom and is wrong here: cancelling a run \
             mid-publish can leave some tags of a release stitched and others \
             not. A publish that has begun finishes, and the next run supersedes \
             it in order.
             """
    end
  end

  test "the verification jobs are left ungrouped" do
    jobs = Workflow.jobs()

    grouped =
      jobs
      |> Map.keys()
      |> Enum.filter(&Workflow.runs_on_pull_request?(&1, jobs))
      |> Enum.filter(&(concurrency(&1) != nil))
      |> Enum.sort()

    assert grouped == [],
           """
           These jobs run for a pull request and yet declare a concurrency \
           group: #{inspect(grouped)}

           Verification is exempt on purpose: those jobs write nothing outside \
           their own run, so serializing them doubles the wall clock of a busy \
           day and protects nothing.
           """
  end

  test "the publish-side set is the four jobs the docs describe" do
    # The derivation is structural, so this is the sanity check on the
    # derivation rather than on the workflow: if a rename or a new job moves
    # the set, the docs and the block comment in ci.yml name a set that no
    # longer exists.
    assert publish_side() == ~w[image-build meta publish verify-published]
  end

  defp publish_side do
    jobs = Workflow.jobs()

    jobs
    |> Map.keys()
    |> Enum.reject(&Workflow.runs_on_pull_request?(&1, jobs))
    |> Enum.sort()
  end

  defp concurrency(key) do
    jobs = Workflow.jobs()

    key |> Workflow.block!(jobs) |> Workflow.concurrency()
  end
end
