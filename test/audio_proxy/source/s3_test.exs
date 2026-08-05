defmodule AudioProxy.Source.S3Test do
  # The allowlist lives in `:persistent_term`, which is global.
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.ErrorJSON
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

    test "bounds the body before splitting it, not after" do
      # A separator-free body is scanned in full by `String.split/3`, so the
      # bound has to come first. Cheap here (0.177 ms for 10 MB), but the
      # ordering is the invariant.
      assert S3.parse(String.duplicate("a", 100_000)) == {:error, :source_too_long}
      assert S3.parse(String.duplicate("a", 1089)) == {:error, :source_too_long}
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

  describe "the storage seam classifies every failure by cause" do
    # `AudioProxy.S3`'s whole error type, one row per shape. Enumerated here
    # rather than sampled: the mapping *is* this slice's decision, and a shape
    # that lost its clause would answer 500 to a live request.
    @shapes [
      {:not_found, :not_found},
      {:access_denied, :not_found},
      {{:http, 400, ""}, :not_found},
      {{:http, 404, "<Error><Code>NoSuchBucket</Code></Error>"}, :not_found},
      {{:http, 409, "<Error/>"}, :not_found},
      {{:http, 500, ""}, :upstream_unavailable},
      {{:http, 503, "<Error><Code>SlowDown</Code></Error>"}, :upstream_unavailable},
      {{:transport, :econnrefused}, :upstream_unavailable},
      {{:transport, :timeout}, :upstream_unavailable},
      {:not_configured, :not_configured}
    ]

    test "each S3 error shape maps to its own reason" do
      for {shape, reason} <- @shapes do
        assert S3.classify(shape) == reason,
               "expected #{inspect(shape)} to classify as #{inspect(reason)}"
      end
    end

    test "each reason maps on to the status the API contract documents" do
      statuses = %{not_found: 404, not_configured: 500, upstream_unavailable: 502}

      for {shape, reason} <- @shapes do
        expected = Map.fetch!(statuses, reason)

        assert {^expected, _headers, _body} = ErrorJSON.render(S3.classify(shape)),
               "expected #{inspect(shape)} to answer #{expected}"
      end
    end

    # The property the blind 404 exists for: a bucket policy that denies HEAD
    # must not tell a client that the object it named is there.
    test "a denied credential answers byte-identically to a missing object" do
      assert S3.classify(:access_denied) == S3.classify(:not_found)

      assert ErrorJSON.render(S3.classify(:access_denied)) ==
               ErrorJSON.render(S3.classify(:not_found))
    end

    # And the property this slice adds: an outage must *not* be that 404.
    test "an outage stays distinguishable from a missing object" do
      for shape <- [{:http, 503, ""}, {:transport, :econnrefused}] do
        refute ErrorJSON.render(S3.classify(shape)) == ErrorJSON.render(S3.classify(:not_found))
      end
    end

    test "an unmapped shape raises rather than picking a plausible status" do
      # `:invalid_range` belongs to `get_stream/3`, which this module never
      # calls. There is no catch-all, so it fails a test rather than a request.
      #
      # Called through `apply/3` because the set-theoretic checker is right
      # about the direct call — `classify/1` has no clause for this — and would
      # warn on the very thing being asserted.
      assert_raise FunctionClauseError, fn -> apply(S3, :classify, [:invalid_range]) end
    end

    test "refuses a hand-built source with a verdict rather than raising" do
      assert S3.stat({:s3, nil, "a.wav"}) == {:error, :not_allowed}
      assert S3.ffmpeg_input({:s3, "masters"}) == {:error, :not_allowed}
    end
  end

  describe "the storage seam, unconfigured" do
    setup do
      put_config(%{
        s3: %{
          region: "us-east-1",
          access_key_id: nil,
          secret_access_key: nil,
          session_token: nil,
          endpoint: nil,
          addressing: :virtual,
          ca_bundle: nil
        }
      })

      :ok
    end

    test "both callbacks report an operator fault, not a missing object" do
      source = {:s3, "masters", "a.wav"}

      assert S3.stat(source) == {:error, :not_configured}
      assert S3.ffmpeg_input(source) == {:error, :not_configured}

      assert {500, _headers, _body} = ErrorJSON.render(:not_configured)
    end
  end
end
