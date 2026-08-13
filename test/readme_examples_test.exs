defmodule AudioProxy.ReadmeExamplesTest do
  @moduledoc """
  Parses the example URLs out of the README's quick start and checks they still
  describe this build.

  The README promises that each example describes a renderable variant. That
  promise rots the moment a validation rule tightens — the options parser has
  already gained rules twice for combinations no encoder can honour, and each
  time an example could have quietly become a 422 that nobody noticed until a
  reader pasted it.

  This file also guarded the README's configuration table, which no longer
  exists: `condense-readme` reduced the README to a landing page, and the `AP_`
  surface is now published once, in `llms-full.txt`, where
  `AudioProxy.LlmsDocsTest` holds it against `AudioProxy.Config.variables/0`.
  That is the one guarded copy. The documentation site's configuration page is
  in another repository and is reviewed rather than compared, the same as every
  authored page there.

  Reading the file rather than restating its contents here is the point: a
  duplicated list would drift in exactly the way this is meant to prevent.
  """

  use ExUnit.Case, async: true

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

  # The count is the backstop against this guard being satisfied by an empty
  # README: a quick start trimmed to nothing would otherwise pass while checking
  # nothing. Three is what the quick start carries, not a floor chosen loosely.
  test "the README contains the examples this test is meant to guard" do
    found = examples()

    assert length(found) >= 3,
           "expected the README's quick-start examples to still be there, found #{inspect(found)}"
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
end
