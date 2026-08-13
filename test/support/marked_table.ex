defmodule AudioProxy.MarkedTable do
  @moduledoc """
  Reads a markdown table out of an HTML-comment-marked region of a published
  document.

  `llms-full.txt` and `README.md` both carry hand-written tables that a drift
  guard compares against the implementation — option keys, error rows,
  configuration variables. Each is fenced by `<!-- <name>-table:start -->` and
  `<!-- <name>-table:end -->`, comments chosen because they are invisible in a
  rendered document.

  This module exists because the second such guard grew a second parser. The
  two were not identical: one tolerated a line holding nothing but `|` and the
  other raised `ArgumentError` on it, which is precisely the divergence a
  duplicated helper produces and nobody notices until a document is edited.

  ## The shape a table must keep

  Inside a marked region, a line counts as a row when it starts with `|` and
  its first cell is a single backticked token — which is what skips the header
  and the `|---|` separator without either being named here. A cell that is not
  a single backticked token reads as `nil`, so a guard comparing first cells
  gets the token and a guard reading further cells still sees the row's shape.

  A missing marker raises `MatchError` rather than returning nothing: a guard
  that silently parsed an empty table would pass while checking nothing.
  """

  @doc """
  The rows of a marked table, each as its list of cell tokens.

  A cell that is not exactly one backticked token is `nil`. Rows whose *first*
  cell is not backticked — the header, the separator — are dropped entirely.
  """
  @spec rows(binary(), binary()) :: [[String.t() | nil]]
  def rows(document, name) when is_binary(document) and is_binary(name) do
    document
    |> region(name)
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(&cells/1)
    |> Enum.reject(&(&1 == []))
  end

  @doc """
  The first cell of every row of a marked table.

  What a coverage guard almost always wants: the option key, the variable name,
  the thing the row is *about*.
  """
  @spec first_cells(binary(), binary()) :: [String.t()]
  def first_cells(document, name) do
    document |> rows(name) |> Enum.map(fn [first | _rest] -> first end)
  end

  defp region(document, name) do
    [_before, inside | _after] =
      String.split(document, ["<!-- #{name}-table:start -->", "<!-- #{name}-table:end -->"])

    lines(inside)
  end

  defp cells(row) do
    row
    |> String.split("|", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn cell ->
      case Regex.run(~r/^`([^`]+)`$/, cell) do
        [_match, token] -> token
        nil -> nil
      end
    end)
    |> case do
      # Also the empty case — a line of nothing but pipes splits to `[]`, which
      # is not a row and must not reach a caller pattern-matching a first cell.
      [nil | _rest] -> []
      [] -> []
      cells -> cells
    end
  end

  defp lines(document), do: document |> String.split("\n") |> Enum.map(&String.trim/1)
end
