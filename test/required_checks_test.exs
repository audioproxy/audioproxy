defmodule AudioProxy.RequiredChecksTest do
  @moduledoc """
  The required-check table in `docs/development.md` against the checks
  `.github/workflows/ci.yml` actually produces.

  Branch protection is a repo setting, so no commit can gate a merge directly;
  what a commit can do is keep the instructions for that setting from
  drifting. The table names every check that gates publishing — the jobs
  `publish` transitively `needs:`, restricted to those that run on a pull
  request — with each matrix job expanded per leg, because GitHub lists status
  checks by job name and a matrix job reports one check per leg.

  Both directions are the failure. A check the workflow produces but the table
  omits is an ungated merge; a check the table names that the workflow no
  longer produces is a rule that blocks every pull request forever, showing
  *Expected — waiting for status* on a run that finished. Renaming a job,
  adding a matrix leg, and adding or retiring a gating job all land here
  first, as a red `test` job rather than a settings mismatch.

  The derivation below is a second, deliberately small implementation of
  GitHub's check naming (`name (leg)`), line-based per the dependency policy
  rather than a YAML parser. Where it cannot expand a name it raises, because
  asserting a wrong name is exactly the drift it exists to catch.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.MarkedTable
  alias AudioProxy.Workflow

  defp table, do: MarkedTable.rows(File.read!("docs/development.md"), "required-checks")

  test "the documented checks are exactly the ones that gate publishing" do
    documented = MapSet.new(table(), fn [check | _rest] -> check end)
    gating = MapSet.new(gating_checks())

    missing = difference(gating, documented)
    stale = difference(documented, gating)

    assert missing == [],
           """
           Checks that gate publishing but docs/development.md does not list: \
           #{inspect(missing)}
           Add a row for each to the required-checks table, then update the
           branch-protection rule on main to match, in the same change.
           """

    assert stale == [],
           """
           Checks docs/development.md lists that the workflow no longer produces: \
           #{inspect(stale)}
           Remove the stale rows — and the same names from the branch-protection
           rule on main, or every pull request will block on a check that never
           reports.
           """
  end

  test "every row records whether the check is required to merge" do
    # The second column is what lets a deliberate exclusion be recorded
    # rather than implied: a gating job that does not gate merges is a `no`
    # beside its reason, never a missing row.
    for [check, required | _rest] <- table() do
      assert required in ["yes", "no"],
             "the row for #{inspect(check)} must mark required-to-merge as `yes` or `no`"
    end
  end

  test "the table repeats no check" do
    # The set comparison above collapses a duplicated row and passes; same
    # closure as in `AudioProxy.LlmsDocsTest`.
    checks = Enum.map(table(), fn [check | _rest] -> check end)

    assert checks -- Enum.uniq(checks) == [], "the required-checks table repeats a check"
  end

  ## Derivation

  # Everything `publish` transitively needs gates publishing; of those, only
  # the jobs that run on a pull request can be required checks. `meta` is
  # push-only by its `if:`, and `image-build` needs `meta`, so both drop out
  # here structurally rather than by being named.
  defp gating_checks do
    jobs = Workflow.jobs()

    "publish"
    |> Workflow.closure(jobs)
    |> Enum.filter(&Workflow.runs_on_pull_request?(&1, jobs))
    |> Enum.flat_map(&Workflow.check_names(&1, jobs))
  end

  defp difference(a, b), do: a |> MapSet.difference(b) |> Enum.sort()
end
