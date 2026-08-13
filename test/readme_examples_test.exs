defmodule AudioProxy.ReadmeExamplesTest do
  @moduledoc """
  Parses the example URLs and the configuration table out of the README and
  checks they still describe this build.

  The README promises that each example describes a renderable variant. That
  promise rots the moment a validation rule tightens — the options parser has
  already gained rules twice for combinations no encoder can honour, and each
  time an example could have quietly become a 422 that nobody noticed until a
  reader pasted it.

  Its configuration table is the second hand-maintained copy of the `AP_`
  surface — `llms-full.txt` holds the first — and drifts for the same reason:
  a variable arrives with a slice and nothing fails when the table does not
  grow a row. It is checked against `AudioProxy.Config.variables/0` here, by
  name, on the same terms `AudioProxy.LlmsDocsTest` states: defaults are
  reviewed, not compared, because the two files word a derived default
  differently on purpose.

  Reading the file rather than restating its contents here is the point: a
  duplicated list would drift in exactly the way this is meant to prevent.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Config
  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.Options

  # `/insecure/<options>/$SRC` — the dev-mode spelling the README uses, with the
  # source held in a shell variable so the examples stay readable.
  @example_re ~r{/insecure/(?<options>[^"]+?)/\$SRC}

  defp examples do
    "README.md"
    |> File.read!()
    |> then(&Regex.scan(@example_re, &1, capture: ["options"]))
    |> List.flatten()
    |> Enum.uniq()
  end

  test "the README contains the examples this test is meant to guard" do
    found = examples()

    assert length(found) >= 6,
           "expected the README's usage examples to still be there, found #{inspect(found)}"
  end

  test "every example option string parses and validates" do
    for options <- examples(), options != "info" do
      assert {:ok, _opts} = Options.parse(options),
             """
             README example does not parse: #{options}

             Either the example is wrong or a validation rule tightened under it.
             """
    end
  end

  test "every example builds a command and has a content type" do
    for options <- examples(), options != "info" do
      {:ok, opts} = Options.parse(options)

      argv = Command.build(opts, "https://example.test/piece.wav", type: :http)

      assert List.last(argv) == "pipe:1"
      assert Command.content_type(opts) =~ ~r"^[a-z]+/[a-z0-9.+-]+$"
    end
  end

  # The README says the options are the cache key; if two examples normalized
  # alike they would be one variant wearing two descriptions, which would make
  # the examples misleading about what the URL space buys you.
  test "the examples describe distinct variants" do
    normalized =
      examples()
      |> Enum.reject(&(&1 == "info"))
      |> Enum.map(fn options ->
        {:ok, opts} = Options.parse(options)
        Options.normalize(opts)
      end)

    assert length(Enum.uniq(normalized)) == length(normalized)
  end

  describe "the configuration table" do
    test "documents exactly the variables the config reads" do
      documented = MapSet.new(config_variables())
      known = MapSet.new(Config.variables())

      missing = difference(known, documented)
      stale = difference(documented, known)

      assert missing == [],
             """
             Variables AudioProxy.Config reads but the README does not document: \
             #{inspect(missing)}
             Add a row for each to the configuration table in README.md.
             """

      assert stale == [],
             """
             Variables the README documents that AudioProxy.Config does not read: \
             #{inspect(stale)}
             Remove the stale rows from README.md.
             """
    end

    test "repeats no variable" do
      # The check above compares sets, where a duplicated row collapses and
      # passes — publishing a second copy, with whatever it claims, unchecked.
      variables = config_variables()

      assert variables -- Enum.uniq(variables) == []
    end
  end

  defp difference(a, b), do: a |> MapSet.difference(b) |> Enum.sort()

  # The first cell of every row in the marked region, on the same terms
  # `AudioProxy.LlmsDocsTest` parses its tables: a line starting with `|` whose
  # first cell is a single backticked token, which skips the header and the
  # `|---|` separator. The markers are HTML comments, so they are invisible in
  # a rendered README.
  defp config_variables do
    [_before, inside | _after] =
      "README.md"
      |> File.read!()
      |> String.split(["<!-- config-table:start -->", "<!-- config-table:end -->"])

    inside
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.flat_map(fn row ->
      row
      |> String.split("|", trim: true)
      |> hd()
      |> String.trim()
      |> then(&Regex.run(~r/^`([^`]+)`$/, &1))
      |> case do
        [_match, variable] -> [variable]
        nil -> []
      end
    end)
  end
end
