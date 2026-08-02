defmodule AudioProxy.Source.S3Test do
  # The allowlist lives in `:persistent_term`, which is global.
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Source
  alias AudioProxy.Source.S3

  defp enc(source), do: "enc/" <> Base.url_encode64(source, padding: false)

  describe "parse/1" do
    test "splits a bucket and a key at the first slash" do
      assert S3.parse("masters/2026/piece-final.wav") ==
               {:ok, {:s3, "masters", "2026/piece-final.wav"}}
    end

    test "refuses a source missing either half" do
      assert S3.parse("masters") == {:error, :missing_key}
      assert S3.parse("masters/") == {:error, :missing_key}
      assert S3.parse("/a.wav") == {:error, :missing_bucket}
      assert S3.parse("") == {:error, :missing_bucket}
    end

    test "keeps a key's own empty segments, which S3 treats as distinct objects" do
      assert S3.parse("masters/a//b.wav") == {:ok, {:s3, "masters", "a//b.wav"}}
      assert S3.parse("masters/./a.wav") == {:ok, {:s3, "masters", "./a.wav"}}
    end

    test "refuses a bucket or key past S3's own maxima" do
      assert S3.parse(String.duplicate("b", 64) <> "/a.wav") == {:error, :source_too_long}
      assert S3.parse("masters/" <> String.duplicate("k", 1025)) == {:error, :source_too_long}

      assert {:ok, _at_the_limit} =
               S3.parse(String.duplicate("b", 63) <> "/" <> String.duplicate("k", 1024))
    end
  end

  describe "through the resolver" do
    test "the s3 form parses, case-insensitively in the scheme" do
      assert Source.parse("plain/s3://masters/2026/piece-final.wav") ==
               {:ok, {:s3, "masters", "2026/piece-final.wav"}}

      assert Source.parse("plain/S3://masters/a.wav") == {:ok, {:s3, "masters", "a.wav"}}
    end

    test "an escaped key arrives as its original bytes" do
      assert Source.parse("plain/s3://masters/a%20track.wav") ==
               {:ok, {:s3, "masters", "a track.wav"}}

      # `+` is a literal plus in a path; the plus-means-space convention
      # belongs to query strings.
      assert Source.parse("plain/s3://masters/a+track.wav") ==
               {:ok, {:s3, "masters", "a+track.wav"}}

      assert Source.parse("plain/s3://masters/100%25.wav") ==
               {:ok, {:s3, "masters", "100%.wav"}}
    end

    test "both encodings yield the same source and the same canonical string" do
      source = "s3://masters/a track.wav"

      assert {:ok, from_plain} = Source.parse("plain/" <> URI.encode(source))
      assert {:ok, from_enc} = Source.parse(enc(source))

      assert from_plain == from_enc
      assert Source.canonical(from_plain) == Source.canonical(from_enc)
      assert Source.canonical(from_plain) == source
    end

    test "a control character never reaches this type" do
      assert Source.parse(enc("s3://masters/\0a.wav")) == {:error, :control_character}
    end
  end

  describe "canonical/1" do
    test "is the source spelled back out" do
      assert S3.canonical({:s3, "masters", "2026/a.wav"}) == "s3://masters/2026/a.wav"
    end
  end

  describe "authorize/1" do
    test "accepts any bucket when the allowlist is unset, since credentials gate it" do
      put_config(%{source_allowlist: []})

      assert S3.authorize({:s3, "masters", "a.wav"}) == :ok
    end

    test "accepts an exact bucket and refuses one that is not listed" do
      put_config(%{source_allowlist: ["masters", "previews"]})

      assert S3.authorize({:s3, "masters", "a.wav"}) == :ok
      assert S3.authorize({:s3, "secrets", "a.wav"}) == {:error, :not_allowed}
    end

    test "matches a bucket case-sensitively, as S3 does" do
      put_config(%{source_allowlist: ["masters"]})

      assert S3.authorize({:s3, "Masters", "a.wav"}) == {:error, :not_allowed}
    end

    test "honours a trailing-* prefix glob over the operator's own namespace" do
      put_config(%{source_allowlist: ["previews-*"]})

      assert S3.authorize({:s3, "previews-eu", "a.wav"}) == :ok
      assert S3.authorize({:s3, "previews-", "a.wav"}) == :ok
      assert S3.authorize({:s3, "masters", "a.wav"}) == {:error, :not_allowed}
      assert S3.authorize({:s3, "eu-previews", "a.wav"}) == {:error, :not_allowed}
    end

    test "a bare * admits everything" do
      put_config(%{source_allowlist: ["*"]})

      assert S3.authorize({:s3, "anything", "a.wav"}) == :ok
    end

    test "returns a verdict for a hand-built source rather than raising" do
      put_config(%{source_allowlist: ["masters"]})

      assert S3.authorize({:s3, nil, "a.wav"}) == {:error, :not_allowed}
      assert S3.authorize({:s3, "masters"}) == {:error, :not_allowed}
      assert S3.authorize({:s3, "", "a.wav"}) == {:error, :not_allowed}
    end
  end

  describe "the storage seam" do
    test "reports that no backend has shipped yet, rather than crashing" do
      source = {:s3, "masters", "a.wav"}

      assert S3.stat(source) == {:error, :no_backend}
      assert S3.ffmpeg_input(source) == {:error, :no_backend}
    end
  end
end
