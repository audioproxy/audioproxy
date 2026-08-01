defmodule AudioProxy.SourcePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AudioProxy.CacheKey
  alias AudioProxy.FakeSourceType
  alias AudioProxy.Source
  alias AudioProxy.SourceGenerators

  @types [FakeSourceType]
  @escape_re ~r/%[0-9A-Fa-f]{2}/

  defp plain(source), do: "plain/" <> URI.encode(source)
  defp enc(source), do: "enc/" <> Base.url_encode64(source, padding: false)
  defp source(body), do: "fake://" <> body
  defp parse(segment), do: Source.parse(segment, @types)

  property "both encodings parse to the same typed source" do
    check all(body <- SourceGenerators.body()) do
      source = source(body)

      assert {:ok, from_plain} = parse(plain(source))
      assert {:ok, from_enc} = parse(enc(source))

      assert from_plain == from_enc
    end
  end

  property "a body carrying a literal percent still round-trips through both encodings" do
    check all(body <- SourceGenerators.percent_body()) do
      source = source(body)

      assert {:ok, from_plain} = parse(plain(source))
      assert {:ok, from_enc} = parse(enc(source))

      assert from_plain == from_enc
      assert Source.canonical(from_plain, @types) == source
    end
  end

  property "the plain form round-trips the decoded source exactly" do
    check all(body <- SourceGenerators.body()) do
      source = source(body)

      assert {:ok, parsed} = parse(plain(source))
      assert Source.canonical(parsed, @types) == source
    end
  end

  property "canonical is stable across encodings and free of percent-escapes" do
    check all(body <- SourceGenerators.body()) do
      source = source(body)

      assert {:ok, from_plain} = parse(plain(source))
      assert {:ok, from_enc} = parse(enc(source))

      canonical = Source.canonical(from_plain, @types)

      assert canonical == Source.canonical(from_enc, @types)
      refute Regex.match?(@escape_re, canonical)
    end
  end

  property "the cache key is the same whichever encoding was requested" do
    check all(body <- SourceGenerators.body()) do
      source = source(body)

      assert {:ok, from_plain} = parse(plain(source))
      assert {:ok, from_enc} = parse(enc(source))

      assert CacheKey.derive!("f:opus", Source.canonical(from_plain, @types)) ==
               CacheKey.derive!("f:opus", Source.canonical(from_enc, @types))
    end
  end

  property "an unregistered scheme is refused however the source is spelled" do
    check all(body <- SourceGenerators.body()) do
      source = "unregistered://" <> body

      assert parse(plain(source)) == {:error, :unknown_scheme}
      assert parse(enc(source)) == {:error, :unknown_scheme}
    end
  end

  property "a control code point anywhere in the body is refused" do
    check all(
            body <- SourceGenerators.body(),
            codepoint <- member_of(["\0", "\n", "\u0085", "\u2028", "\u2029", "\u202E"]),
            position <- integer(0..40)
          ) do
      {head, tail} = String.split_at(body, position)
      source = source(head <> codepoint <> tail)

      assert parse(enc(source)) == {:error, :control_character}
    end
  end
end
