defmodule AudioProxy.Workflow do
  @moduledoc """
  Reads `.github/workflows/ci.yml` as jobs, for the drift guards that assert
  something about the workflow's shape.

  Two guards need this now. `AudioProxy.RequiredChecksTest` derives the checks
  that gate publishing and compares them against the table in
  `docs/development.md`; `AudioProxy.PublishConcurrencyTest` asserts that the
  publish-side jobs — and only those — carry the `concurrency:` group that
  serializes them. Both need the same three facts about a job: its `name:`, its
  `needs:`, and whether its `if:` restricts it to a push.

  It is deliberately line-based rather than a YAML parser, per the dependency
  policy: the workflow is written by hand in a house style this reads reliably,
  and a guard that needs a new dependency is a guard that does not get written.
  Where it cannot answer, it raises — asserting against a job it mis-parsed is
  exactly the drift it exists to catch.

  The rule is the one every other support module carries: a guard that needs to
  read the workflow reaches for this, and never grows its own regex beside it.
  `AudioProxy.MarkedTable` exists because the second table guard grew a second
  parser and the two disagreed; this module is that lesson applied before the
  fact.
  """

  @arch_token "${{ matrix.arch }}"

  @doc """
  Every job in `ci.yml`, as `%{key => block}`.

  Job keys sit at indent 2 under `jobs:`; everything until the next key is that
  job's block. Comments between jobs ride along in the preceding block, where
  nothing below matches them.

  Read when a test runs, not when this module compiles — same idiom and reason
  as `AudioProxy.LlmsDocsTest`: `mix test --only ffmpeg` still compiles every
  test file inside the release image's test stage.
  """
  def jobs do
    [_prelude, body] = String.split(source(), "\njobs:\n", parts: 2)

    [_before_first | rest] =
      Regex.split(~r/^  ([a-z][a-z0-9_-]*):$/m, body, include_captures: true)

    rest
    |> Enum.chunk_every(2)
    |> Map.new(fn [header, block] ->
      {header |> String.trim() |> String.trim_trailing(":"), block}
    end)
  end

  @doc "The raw workflow text."
  def source, do: File.read!(".github/workflows/ci.yml")

  @doc """
  A job's block, raising when the key names a job that is not there — which is
  either a `needs:` pointing at a job that moved, or this parser no longer
  reading the workflow.
  """
  def block!(key, jobs) do
    case Map.fetch(jobs, key) do
      {:ok, block} ->
        block

      :error ->
        raise "ci.yml has no job #{inspect(key)} — a `needs:` names a job that moved, " <>
                "or the derivation in #{__MODULE__} no longer parses the workflow"
    end
  end

  @doc """
  A job's `name:`, or its key when it has none — which is GitHub's fallback
  too.

  Exactly indent 4: step-level `name:` lines sit deeper or behind a `- `, so
  they never match.
  """
  def job_name(key, block) do
    case Regex.run(~r/^    name: (.+?)\s*$/m, block) do
      [_line, name] -> name
      nil -> key
    end
  end

  @doc "The job keys a job's `needs:` names, in either YAML form."
  def needs(block) do
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

  @doc """
  A block with its comment lines removed.

  A job's block runs to the next job key, so the block comments that sit
  *between* jobs ride along at the end of the preceding one. That is harmless
  for the field readers above, which anchor on an indented key, and a trap for
  anything that greps a block for prose: a comment explaining `imagetools
  create` reads as a job that runs it. Grep through this.
  """
  def uncommented(block) do
    block
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  @doc "The `arch:` legs of a job's matrix, empty when it has none."
  def arches(block) do
    ~r/^\s+- arch: (\S+)$/m
    |> Regex.scan(block)
    |> Enum.map(fn [_line, arch] -> arch end)
  end

  @doc """
  A job's `concurrency:` group and cancel policy, or `nil` when it declares
  none.

  Indent 4 for the key and 6 for its two fields, so a `concurrency:` at
  workflow level or inside a step cannot be mistaken for a job's.
  """
  def concurrency(block) do
    case Regex.run(~r/^    concurrency:\n((?:      \S.*\n)+)/m, block) do
      nil ->
        nil

      [_match, fields] ->
        %{
          group: field(fields, "group"),
          cancel_in_progress: field(fields, "cancel-in-progress")
        }
    end
  end

  defp field(fields, key) do
    case Regex.run(~r/^      #{Regex.escape(key)}: (.+?)\s*$/m, fields) do
      [_line, value] -> value
      nil -> nil
    end
  end

  @doc """
  Everything a job transitively `needs:`.
  """
  def closure(key, jobs) do
    direct = key |> block!(jobs) |> needs()

    Enum.reduce(direct, MapSet.new(direct), fn need, acc ->
      MapSet.union(acc, closure(need, jobs))
    end)
  end

  @doc """
  Whether a job can run for a pull request.

  A job-level `if:` keyed on the push event never does, and neither does
  anything downstream of such a job — a skipped job skips everything that
  needs it. `>-` folds the condition across continuation lines, so those are
  read too.
  """
  def runs_on_pull_request?(key, jobs) do
    block = block!(key, jobs)

    not push_only?(block) and Enum.all?(needs(block), &runs_on_pull_request?(&1, jobs))
  end

  defp push_only?(block) do
    case Regex.run(~r/^    if:(.*(?:\n {6}\S.*)*)/m, block) do
      nil ->
        false

      [_match, condition] ->
        cond do
          # Names the pull_request event positively, so it runs for one.
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

  @doc """
  The status-check names a job reports.

  GitHub names a matrix job's checks per leg: `name (leg)`. A name that
  interpolates anything this cannot expand raises rather than asserting a name
  GitHub will never report.
  """
  def check_names(key, jobs) do
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
end
