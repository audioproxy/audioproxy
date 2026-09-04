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
  rather than a YAML parser. Where it cannot answer it raises — an unexpandable
  name, a block-form `needs:`, an `if:` it cannot classify — because asserting
  against a job it mis-parsed is exactly the drift it exists to catch.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.MarkedTable

  @arch_token "${{ matrix.arch }}"

  # Read when a test runs, not when this file compiles — same idiom and reason
  # as `AudioProxy.LlmsDocsTest`: `mix test --only ffmpeg` still compiles every
  # test file inside the release image's test stage.
  defp workflow, do: File.read!(".github/workflows/ci.yml")
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
    jobs = jobs()

    "publish"
    |> closure(jobs)
    |> Enum.filter(&runs_on_pull_request?(&1, jobs))
    |> Enum.flat_map(&check_names(&1, jobs))
  end

  defp closure(key, jobs) do
    direct = key |> block!(jobs) |> needs()

    Enum.reduce(direct, MapSet.new(direct), fn need, acc ->
      MapSet.union(acc, closure(need, jobs))
    end)
  end

  defp runs_on_pull_request?(key, jobs) do
    block = block!(key, jobs)

    not push_only?(block) and Enum.all?(needs(block), &runs_on_pull_request?(&1, jobs))
  end

  # GitHub names a matrix job's checks per leg: `name (leg)`. A name that
  # interpolates anything this cannot expand raises rather than asserting a
  # name GitHub will never report.
  defp check_names(key, jobs) do
    block = block!(key, jobs)
    name = job_name(key, block)

    cond do
      String.contains?(name, @arch_token) ->
        case arches(block) do
          [] -> raise "job #{key} interpolates matrix.arch but lists no legs"
          legs -> Enum.map(legs, &String.replace(name, @arch_token, &1))
        end

      String.contains?(name, "${{") ->
        raise "job #{key} has a name this guard cannot expand: #{name}"

      true ->
        [name]
    end
  end

  ## ci.yml, line-based

  # Job keys sit at indent 2 under `jobs:`; everything until the next key is
  # that job's block. Comments between jobs ride along in the preceding block,
  # where nothing below matches them.
  defp jobs do
    [_prelude, body] = String.split(workflow(), "\njobs:\n", parts: 2)

    [_before_first | rest] =
      Regex.split(~r/^  ([a-z][a-z0-9_-]*):$/m, body, include_captures: true)

    rest
    |> Enum.chunk_every(2)
    |> Map.new(fn [header, block] ->
      {header |> String.trim() |> String.trim_trailing(":"), block}
    end)
  end

  defp block!(key, jobs) do
    case Map.fetch(jobs, key) do
      {:ok, block} ->
        block

      :error ->
        raise "ci.yml has no job #{inspect(key)} — a `needs:` names a job that moved, " <>
                "or the derivation in #{__ENV__.file} no longer parses the workflow"
    end
  end

  # Exactly indent 4: step-level `name:`/`if:` lines sit deeper or behind a
  # `- `, so they never match. A job with no `name:` reports under its key,
  # which is GitHub's fallback too.
  defp job_name(key, block) do
    case Regex.run(~r/^    name: (.+?)\s*$/m, block) do
      [_line, name] -> name
      nil -> key
    end
  end

  defp needs(block) do
    if Regex.match?(~r/^    needs:\s*$/m, block) do
      raise "a job writes `needs:` as a block list; this parser reads the inline " <>
              "form only, and returning no dependencies would silently shrink " <>
              "every derivation built on it"
    end

    case Regex.run(~r/^    needs: (.+?)\s*$/m, block) do
      nil ->
        []

      [_line, value] ->
        value
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  defp arches(block) do
    ~r/^\s+- arch: (\S+)$/m
    |> Regex.scan(block)
    |> Enum.map(fn [_line, arch] -> arch end)
  end

  # A job-level `if:` keyed on the push event never runs on a pull request.
  # `>-` folds the condition across continuation lines, so those are read too.
  defp push_only?(block) do
    case Regex.run(~r/^    if:(.*(?:\n {6}\S.*)*)/m, block) do
      nil ->
        false

      [_match, condition] ->
        cond do
          String.contains?(condition, "github.event_name == 'pull_request'") ->
            false

          String.contains?(condition, "github.event_name == 'push'") ->
            true

          String.contains?(condition, "github.event_name != 'pull_request'") ->
            true

          not String.contains?(condition, "github.event_name") ->
            false

          true ->
            raise "a job's `if:` tests github.event_name in a form this guard " <>
                    "cannot classify: #{String.trim(condition)}"
        end
    end
  end

  defp difference(a, b), do: a |> MapSet.difference(b) |> Enum.sort()
end
