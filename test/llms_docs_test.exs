defmodule AudioProxy.LlmsDocsTest do
  @moduledoc """
  `llms.txt` and `llms-full.txt`: that they are shaped like an llms.txt, and —
  the part that earns its keep — that they still describe this build.

  A document an agent reads instead of the code is only worth publishing while
  the two agree, and prose cannot be checked. Coverage can: the option table
  must name exactly the keys the parser knows, the error table exactly the
  rows `AudioProxy.ErrorJSON` renders, and the worked signing example must be
  what `AudioProxy.Signature.sign/3` actually produces. Each failure names the
  key, row or value that moved, so the fix is to the document rather than to
  this test.

  The parsed regions are delimited by HTML comments in the file itself, whose
  footer comment states the shape. Everything outside them is prose.

  Sibling of `AudioProxy.ReadmeExamplesTest`, and for the same reason: reading
  the published file beats restating its contents here, since a copy would
  drift in exactly the way this is meant to prevent.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.ErrorJSON
  alias AudioProxy.Options
  alias AudioProxy.Signature

  # Read when a test runs, not when this file compiles. `mix test --only
  # ffmpeg` still *compiles* every test file, so a compile-time read makes
  # these documents a build input of any image carrying the suite — which is
  # how the release image's test stage broke on a file it never runs a test
  # against. Same idiom as `AudioProxy.ReadmeExamplesTest`.
  defp index, do: File.read!("llms.txt")
  defp full, do: File.read!("llms-full.txt")

  describe "llms.txt format" do
    test "has exactly one H1" do
      h1s = Enum.filter(index_lines(), &String.starts_with?(&1, "# "))

      assert length(h1s) == 1, "expected one H1, found #{inspect(h1s)}"
    end

    test "the H1 is followed by a blockquote summary" do
      [first | rest] = Enum.reject(index_lines(), &(&1 == ""))

      assert String.starts_with?(first, "# ")
      assert String.starts_with?(hd(rest), "> ")
    end

    test "every list item is a well-formed link entry" do
      # `- [name](url): description` — the convention's own shape. A bare
      # bullet or a link with no gloss is what this catches.
      for line <- index_lines(), String.starts_with?(line, "-") do
        assert line =~ ~r/^- \[[^\]]+\]\([^)]+\): \S/,
               "malformed llms.txt link entry: #{line}"
      end
    end

    test "every list item sits under an H2" do
      index_lines()
      |> Enum.reduce(nil, fn line, section ->
        cond do
          String.starts_with?(line, "## ") ->
            line

          String.starts_with?(line, "-") ->
            assert section, "link entry before any H2 section: #{line}"
            section

          true ->
            section
        end
      end)
    end

    test "llms-full.txt carries the same lead" do
      lines =
        full()
        |> String.replace(~r/<!--.*?-->/s, "")
        |> lines()
        |> Enum.reject(&(&1 == ""))

      [h1 | rest] = lines

      assert String.starts_with?(h1, "# ")
      assert String.starts_with?(hd(rest), "> ")
    end
  end

  describe "drift guards" do
    test "the documented option keys are exactly the parser's" do
      documented = MapSet.new(table("options"), fn [key | _rest] -> key end)
      known = MapSet.new(Options.keys())

      missing = difference(known, documented)
      stale = difference(documented, known)

      assert missing == [],
             """
             Option keys the parser knows but llms-full.txt does not document: \
             #{inspect(missing)}
             Add a row for each to the options table in llms-full.txt.
             """

      assert stale == [],
             """
             Option keys llms-full.txt documents that the parser does not know: \
             #{inspect(stale)}
             Remove the stale rows from llms-full.txt.
             """
    end

    test "the documented error rows are exactly the ones rendered" do
      documented =
        MapSet.new(table("errors"), fn [status, error | _rest] ->
          {String.to_integer(status), error}
        end)

      rendered = MapSet.new(ErrorJSON.rows())

      missing = difference(rendered, documented)
      stale = difference(documented, rendered)

      assert missing == [],
             """
             Error rows this proxy answers but llms-full.txt does not document: \
             #{inspect(missing)}
             Add them to the error table in llms-full.txt.
             """

      assert stale == [],
             """
             Error rows llms-full.txt documents that nothing renders: \
             #{inspect(stale)}
             Remove them from llms-full.txt.
             """
    end

    test "neither table repeats a row" do
      # The guards compare sets, so a duplicated row collapses and passes —
      # and the copy, with whatever prose it carries, is published unchecked.
      # Cheap to close, and the only way the set comparison can be satisfied
      # by a document that is visibly wrong.
      keys = Enum.map(table("options"), fn [key | _rest] -> key end)
      errors = Enum.map(table("errors"), fn [status, error | _rest] -> {status, error} end)

      assert keys -- Enum.uniq(keys) == [], "the options table repeats a key"
      assert errors -- Enum.uniq(errors) == [], "the error table repeats a row"
    end

    test "every documented option key is one the parser knows" do
      for [key | _rest] <- table("options") do
        assert key in Options.keys()
      end
    end

    test "the worked signing example is what the signer produces" do
      %{"key" => key, "salt" => salt, "path" => path, "signature" => signature} =
        signing_example()

      assert Signature.sign(path, Base.decode16!(key), Base.decode16!(salt)) == signature,
             """
             The signing example in llms-full.txt no longer verifies.
             An agent validating its own HMAC against it would conclude its
             implementation is wrong.
             """
    end
  end

  ## Parsing

  defp difference(a, b), do: a |> MapSet.difference(b) |> Enum.sort()

  defp lines(document), do: document |> String.split("\n") |> Enum.map(&String.trim/1)

  # Prose lines only: a `#` or `-` inside a fenced block is shell, not
  # markdown, and llms.txt gains a fence the moment someone adds an example.
  defp index_lines do
    index()
    |> lines()
    |> Enum.reduce({[], false}, fn
      "```" <> _rest, {kept, fenced?} -> {kept, not fenced?}
      _line, {kept, true} -> {kept, true}
      line, {kept, false} -> {[line | kept], false}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Rows of a marked table, as lists of their backticked cell tokens. A line
  # counts as a row only when its first cell is a single backticked token,
  # which skips the header and the `|---|` separator.
  defp table(name) do
    name
    |> region()
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(&cells/1)
    |> Enum.reject(&(&1 == []))
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
      [nil | _rest] -> []
      cells -> cells
    end
  end

  defp region(name) do
    [_before, inside | _after] =
      String.split(full(), ["<!-- #{name}-table:start -->", "<!-- #{name}-table:end -->"])

    lines(inside)
  end

  defp signing_example do
    [_before, inside | _after] =
      String.split(full(), [
        "<!-- signing-example:start -->",
        "<!-- signing-example:end -->"
      ])

    inside
    |> lines()
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^(AP_KEY|AP_SALT|rest-of-path|signature)\s*(?:\(hex\))?\s+(\S+)$/, line) do
        [_match, label, value] -> Map.put(acc, label(label), value)
        nil -> acc
      end
    end)
  end

  defp label("AP_KEY"), do: "key"
  defp label("AP_SALT"), do: "salt"
  defp label("rest-of-path"), do: "path"
  defp label("signature"), do: "signature"
end
