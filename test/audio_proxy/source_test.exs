defmodule AudioProxy.SourceTest do
  use ExUnit.Case, async: true

  alias AudioProxy.FakeSourceType
  alias AudioProxy.OtherFakeSourceType
  alias AudioProxy.Source

  doctest AudioProxy.Source

  @types [FakeSourceType, OtherFakeSourceType]

  defp enc(source), do: "enc/" <> Base.url_encode64(source, padding: false)
  defp plain(source), do: "plain/" <> URI.encode(source)
  defp parse(segment), do: Source.parse(segment, @types)

  describe "registered types" do
    test "none ship with this slice" do
      assert Source.types() == []
    end

    test "so every source is an unknown scheme until one is registered" do
      assert Source.parse("plain/fake://body") == {:error, :unknown_scheme}
      assert Source.parse(enc("s3://masters/a.wav")) == {:error, :unknown_scheme}
    end
  end

  describe "dispatch" do
    test "hands the decoded body to the type claiming the scheme" do
      assert parse("plain/fake://previews/track.wav") == {:ok, {:fake, "previews/track.wav"}}
      assert parse("plain/other://previews/track.wav") == {:ok, {:other, "previews/track.wav"}}
    end

    test "the scheme is matched case-insensitively" do
      assert parse("plain/FAKE://body") == {:ok, {:fake, "body"}}
      assert parse("plain/Fake://body") == {:ok, {:fake, "body"}}
    end

    test "only the first :// splits, so a body may contain another" do
      assert parse(enc("fake://wrapped/https://inner.example/a.wav")) ==
               {:ok, {:fake, "wrapped/https://inner.example/a.wav"}}
    end

    test "the type's own error is returned unchanged" do
      assert parse("plain/fake://") == {:error, :empty_body}
    end

    test "an unregistered scheme is refused" do
      assert parse("plain/s3://masters/a.wav") == {:error, :unknown_scheme}
      assert parse("plain/ftp://x/y") == {:error, :unknown_scheme}
      assert parse("plain/file:///etc/passwd") == {:error, :unknown_scheme}
    end

    test "a source with no scheme at all is refused" do
      assert parse("plain/masters/a.wav") == {:error, :unknown_scheme}
      assert parse("plain/fake:/body") == {:error, :unknown_scheme}
    end

    test "accepts a segment list, joined with /" do
      assert parse(["plain", "fake:", "", "a", "b.wav"]) == {:ok, {:fake, "a/b.wav"}}
    end
  end

  describe "encodings" do
    test "both forms yield the same typed source and canonical string" do
      source = "fake://previews/track.wav"

      assert {:ok, from_plain} = parse(plain(source))
      assert {:ok, from_enc} = parse(enc(source))

      assert from_plain == from_enc
      assert Source.canonical(from_plain, @types) == Source.canonical(from_enc, @types)
      assert Source.canonical(from_plain, @types) == source
    end

    test "padded base64url is accepted too" do
      source = "fake://abc.wav"
      padded = "enc/" <> Base.url_encode64(source)

      assert String.ends_with?(padded, "=")
      assert parse(padded) == parse(enc(source))
    end

    test "an unknown encoding prefix is refused" do
      assert parse("fake://body") == {:error, :unknown_encoding}
      assert parse("raw/fake://body") == {:error, :unknown_encoding}
      assert parse("") == {:error, :unknown_encoding}
    end

    test "an empty source is refused" do
      assert parse("plain/") == {:error, :empty_source}
      assert parse("enc/") == {:error, :empty_source}
    end

    test "an undecodable enc payload is refused" do
      assert parse("enc/not base64!") == {:error, :invalid_encoding}
    end

    test "an enc payload that is not valid UTF-8 is refused" do
      assert parse("enc/" <> Base.url_encode64(<<0xFF, 0xFE>>, padding: false)) ==
               {:error, :invalid_encoding}
    end
  end

  describe "escaping" do
    test "a space round-trips" do
      assert parse("plain/fake://a%20track.wav") == {:ok, {:fake, "a track.wav"}}
    end

    test "a plus stays a plus" do
      assert parse("plain/fake://a+track.wav") == {:ok, {:fake, "a+track.wav"}}
      assert parse("plain/fake://a%2Btrack.wav") == {:ok, {:fake, "a+track.wav"}}
    end

    test "an escaped slash decodes to a slash" do
      assert parse("plain/fake://a%2Fb.wav") == {:ok, {:fake, "a/b.wav"}}
    end

    test "escape case does not matter" do
      assert parse("plain/fake://a%2fb.wav") == parse("plain/fake://a%2Fb.wav")
    end

    test "a literal percent must be written %25" do
      assert parse("plain/fake://100%25.wav") == {:ok, {:fake, "100%.wav"}}
    end

    test "a malformed escape is refused rather than passed through" do
      assert parse("plain/fake://a%zz.wav") == {:error, :malformed_escape}
      assert parse("plain/fake://a%2.wav") == {:error, :malformed_escape}
      assert parse("plain/fake://trailing%") == {:error, :malformed_escape}
    end

    test "the enc form takes raw bytes, no escaping" do
      assert parse(enc("fake://a track+100%.wav")) == {:ok, {:fake, "a track+100%.wav"}}
    end

    test "decoding happens exactly once" do
      # %2520 is an escaped %20: one decode leaves %20, two would leave a space.
      assert parse("plain/fake://a%2520b.wav") == {:ok, {:fake, "a%20b.wav"}}
    end
  end

  describe "universally refused content" do
    test "ASCII control characters" do
      assert parse("plain/fake://a%00b.wav") == {:error, :control_character}
      assert parse("plain/fake://a%0Ab.wav") == {:error, :control_character}
      assert parse(enc("fake://a\tb.wav")) == {:error, :control_character}
    end

    test "non-ASCII controls, bidi overrides and line separators" do
      for codepoint <- [
            # NEL, a C1 control
            "\u0085",
            # line separator
            "\u2028",
            # paragraph separator
            "\u2029",
            # right-to-left override
            "\u202E",
            # zero-width joiner
            "\u200D"
          ] do
        assert parse(enc("fake://a" <> codepoint <> "b.wav")) == {:error, :control_character}
      end
    end

    test "ordinary non-ASCII text is not a control character" do
      body = "ümläut 日本語.wav"
      assert parse(enc("fake://" <> body)) == {:ok, {:fake, body}}
    end

    test "the check runs before any type sees the source" do
      # The fake type would happily accept this body; it never gets the chance.
      assert parse(enc("fake://\u202Ereversed.wav")) == {:error, :control_character}
    end

    test "every shared reason has a message" do
      for reason <- [
            :unknown_encoding,
            :invalid_encoding,
            :malformed_escape,
            :empty_source,
            :control_character,
            :unknown_scheme
          ] do
        assert is_binary(Source.message(reason))
      end
    end
  end

  describe "delegation" do
    test "canonical/2 routes by tag" do
      assert Source.canonical({:fake, "a.wav"}, @types) == "fake://a.wav"
      assert Source.canonical({:other, "a.wav"}, @types) == "other://a.wav"
    end

    test "authorize/2 returns the type's verdict" do
      assert Source.authorize({:fake, "a.wav"}, @types) == :ok
      assert Source.authorize({:fake, FakeSourceType.denied()}, @types) == {:error, :not_allowed}
    end

    test "stat/2 returns the type's answer, unknown size included" do
      assert Source.stat({:fake, "abc"}, @types) == {:ok, %{size: 3, etag: "etag-abc"}}

      assert Source.stat({:fake, FakeSourceType.sizeless()}, @types) ==
               {:ok, %{size: nil, etag: "etag-sizeless"}}

      assert Source.stat({:fake, FakeSourceType.missing()}, @types) == {:error, :not_found}
    end

    test "ffmpeg_input/2 returns the type's answer" do
      assert Source.ffmpeg_input({:fake, "a.wav"}, @types) == {:ok, "/fake/a.wav"}

      assert Source.ffmpeg_input({:fake, FakeSourceType.missing()}, @types) ==
               {:error, :not_found}
    end

    test "a source whose tag no registered type claims raises" do
      assert_raise ArgumentError, ~r/no source type registered for tag :nope/, fn ->
        Source.canonical({:nope, "a.wav"}, @types)
      end
    end
  end
end
