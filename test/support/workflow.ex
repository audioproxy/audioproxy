defmodule AudioProxy.Workflow do
  @moduledoc """
  Reads `.github/workflows/ci.yml` as jobs, for the guards that assert
  something about CI's shape.

  Line-based rather than a YAML parser, per the dependency policy. Where it
  cannot answer it raises: asserting against a job it mis-parsed is the drift
  it exists to catch.

  Shared because `AudioProxy.MarkedTable` was bought the hard way — a second
  guard grew a second parser and the two disagreed. A guard reads the workflow
  through this, never with its own regex.
  """

  @arch_token "${{ matrix.arch }}"

  @doc """
  Every job in `ci.yml`, as `%{key => block}`.

  Read per test rather than at compile time: `mix test --only ffmpeg` still
  compiles every test file inside the release image's test stage.
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

  def source, do: File.read!(".github/workflows/ci.yml")

  def block!(key, jobs) do
    case Map.fetch(jobs, key) do
      {:ok, block} ->
        block

      :error ->
        raise "ci.yml has no job #{inspect(key)} — a `needs:` names a job that moved, " <>
                "or the derivation in #{__MODULE__} no longer parses the workflow"
    end
  end

  # Indent 4 exactly: step-level `name:` lines sit deeper, and a job with none
  # reports under its key, as it does on GitHub.
  def job_name(key, block) do
    case Regex.run(~r/^    name: (.+?)\s*$/m, block) do
      [_line, name] -> name
      nil -> key
    end
  end

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

  def arches(block) do
    ~r/^\s+- arch: (\S+)$/m
    |> Regex.scan(block)
    |> Enum.map(fn [_line, arch] -> arch end)
  end

  # Indents 4 and 6, so a workflow-level or step-level `concurrency:` cannot be
  # mistaken for a job's.
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

  def closure(key, jobs) do
    direct = key |> block!(jobs) |> needs()

    Enum.reduce(direct, MapSet.new(direct), fn need, acc ->
      MapSet.union(acc, closure(need, jobs))
    end)
  end

  # Downstream of a push-only job counts too: a skipped job skips everything
  # that needs it.
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

  # GitHub reports a matrix job once per leg, as `name (leg)`. An unexpandable
  # name raises rather than asserting one GitHub will never report.
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
