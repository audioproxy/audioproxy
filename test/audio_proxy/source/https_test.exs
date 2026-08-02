defmodule AudioProxy.Source.HttpsTest do
  # The allowlist lives in `:persistent_term`, which is global.
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Source
  alias AudioProxy.Source.Https

  defp enc(source), do: "enc/" <> Base.url_encode64(source, padding: false)

  # `parse/1` receives the body the resolver has already stripped `https://`
  # from, so tests spell sources the way a request does and let the resolver do
  # the stripping wherever the scheme matters.
  defp parse(url), do: Source.parse("plain/" <> url)

  describe "parse/1" do
    test "yields a source carrying the canonical URL" do
      assert Https.parse("media.example/track.wav") ==
               {:ok, {:http, "https://media.example/track.wav"}}
    end

    test "refuses embedded credentials" do
      assert Https.parse("user:pass@media.example/track.wav") ==
               {:error, :userinfo_not_allowed}

      assert Https.parse("user@media.example/track.wav") == {:error, :userinfo_not_allowed}
    end

    test "refuses a URL with no host" do
      assert Https.parse("/track.wav") == {:error, :invalid_url}
      assert Https.parse("") == {:error, :invalid_url}
    end

    test "refuses a host that is empty or dot-only once normalized" do
      # `.` normalized to "" and rendered `https:///a` — a canonical cache key
      # for a string that is not a URL.
      for host <- [".", "..", "...", "...."] do
        assert Https.parse(host <> "/a.wav") == {:error, :invalid_url},
               "expected #{inspect(host)} to be refused"
      end
    end

    test "refuses a host carrying an empty label" do
      # `*.media.example` admitted every one of these, each with its own
      # canonical string — one resource, unboundedly many allowlisted keys.
      for host <- [".media.example", "cdn..media.example", "..media.example", "media.example.."] do
        assert Https.parse(host <> "/a.wav") == {:error, :invalid_url},
               "expected #{inspect(host)} to be refused"
      end

      # The single root dot is still a second spelling, not an empty label.
      assert Https.parse("media.example./a.wav") ==
               {:ok, {:http, "https://media.example/a.wav"}}
    end

    test "refuses a percent-escape in the host" do
      # `URI` does not decode it, so it would ride into the canonical string —
      # and once a backend opens a socket, a client that unescapes would fetch
      # a host the allowlist never matched.
      assert Https.parse("%6D%65dia.example/a.wav") == {:error, :invalid_url}
      assert Https.parse("media%2Eexample/a.wav") == {:error, :invalid_url}
    end

    test "an IP literal is exempt from the label rules" do
      assert Https.parse("[::1]/a.wav") == {:ok, {:http, "https://[::1]/a.wav"}}
      assert Https.parse("1.2.3.4/a.wav") == {:ok, {:http, "https://1.2.3.4/a.wav"}}
    end

    test "refuses a body carrying a scheme of its own" do
      # Unreachable through the resolver, which strips exactly one scheme —
      # but `URI.new/1` would read this as the host `http`, and a hand-built
      # call must not get a source out of it.
      assert Https.parse("http://media.example/track.wav") == {:error, :invalid_url}
      assert Https.parse("https://media.example/track.wav") == {:error, :invalid_url}
    end

    test "refuses a URL or host past its protocol bound" do
      long_path = String.duplicate("a", 2049)
      assert Https.parse("media.example/" <> long_path) == {:error, :source_too_long}

      long_host = String.duplicate("h", 254) <> ".example"
      assert Https.parse(long_host <> "/a.wav") == {:error, :source_too_long}
    end
  end

  describe "through the resolver" do
    test "the https form parses, case-insensitively in the scheme" do
      assert parse("https://media.example/track.wav") ==
               {:ok, {:http, "https://media.example/track.wav"}}

      assert parse("HTTPS://media.example/track.wav") ==
               {:ok, {:http, "https://media.example/track.wav"}}
    end

    test "cleartext is refused at the grammar, naming the scheme as the problem" do
      assert parse("http://media.example/track.wav") == {:error, :unknown_scheme}
      assert Source.message(:unknown_scheme) =~ "scheme"
    end

    test "a raw space is not a URL, however it was encoded" do
      # A space has to be `%20` *in the URL*, which the plain form then escapes
      # again — see the double-escaping test below.
      assert parse("https://media.example/a track.wav") == {:error, :invalid_url}
      assert Source.parse(enc("https://media.example/a track.wav")) == {:error, :invalid_url}
    end

    test "both encodings yield the same source and the same canonical string" do
      source = "https://media.example/2026/piece-final.wav?v=2"

      assert {:ok, from_plain} = Source.parse("plain/" <> URI.encode(source))
      assert {:ok, from_enc} = Source.parse(enc(source))

      assert from_plain == from_enc
      assert Source.canonical(from_plain) == Source.canonical(from_enc)
    end

    test "an already-escaped URL survives the double escaping the plain form needs" do
      source = "https://media.example/a%20b.wav"

      assert {:ok, from_plain} = Source.parse("plain/https://media.example/a%2520b.wav")
      assert {:ok, from_enc} = Source.parse(enc(source))

      assert from_plain == from_enc
      assert Source.canonical(from_plain) == source
    end

    test "a right-to-left override never reaches this type" do
      assert Source.parse(enc("https://media.example/a\u202Eb.wav")) ==
               {:error, :control_character}
    end
  end

  describe "canonical/1: what folds" do
    test "every spelling of one resource converges" do
      spellings = [
        "https://Media.Example.:443/a.wav?",
        "https://media.example/a.wav",
        "https://MEDIA.EXAMPLE/a.wav#section",
        "https://media.example.:443/a.wav"
      ]

      canonicals =
        Enum.map(spellings, fn spelling ->
          assert {:ok, source} = parse(spelling)
          Source.canonical(source)
        end)

      assert Enum.uniq(canonicals) == ["https://media.example/a.wav"]
    end

    test "an absent path becomes /" do
      assert {:ok, source} = parse("https://media.example")
      assert Source.canonical(source) == "https://media.example/"

      assert {:ok, with_query} = parse("https://media.example?a=1")
      assert Source.canonical(with_query) == "https://media.example/?a=1"
    end

    test "a non-default port survives" do
      assert {:ok, source} = parse("https://media.example:8443/a.wav")
      assert Source.canonical(source) == "https://media.example:8443/a.wav"
    end

    test "an IP literal folds onto its canonical spelling, brackets restored" do
      assert {:ok, source} = parse("https://[0:0:0:0:0:0:0:1]/a.wav")
      assert Source.canonical(source) == "https://[::1]/a.wav"

      assert {:ok, v4} = parse("https://1.2.3.4/a.wav")
      assert Source.canonical(v4) == "https://1.2.3.4/a.wav"
    end

    test "inet_aton shorthand is left as a name, so it cannot inherit an entry" do
      # The lenient parser reads `01.2.3.4` as 1.2.3.4 and `1.2` as 1.0.0.2.
      # Folding either would let an allowlist entry admit a second spelling.
      assert {:ok, padded} = parse("https://01.2.3.4/a.wav")
      assert Source.canonical(padded) == "https://01.2.3.4/a.wav"

      assert {:ok, short} = parse("https://1.2/a.wav")
      assert Source.canonical(short) == "https://1.2/a.wav"
    end
  end

  describe "canonical/1: what deliberately does not fold" do
    test "the URL's own escaping is preserved, because origins differ on it" do
      assert {:ok, escaped} = parse("https://h.example/a%252Fb.wav")
      assert {:ok, plain} = parse("https://h.example/a/b.wav")

      assert Source.canonical(escaped) == "https://h.example/a%2Fb.wav"
      assert Source.canonical(escaped) != Source.canonical(plain)
    end

    test "dot segments are left for the origin to resolve" do
      assert {:ok, source} = parse("https://h.example/a/../b.wav")
      assert Source.canonical(source) == "https://h.example/a/../b.wav"
    end
  end

  describe "authorize/1" do
    test "refuses every https source when the allowlist is unset" do
      put_config(%{source_allowlist: []})

      assert Https.authorize({:http, "https://media.example/a.wav"}) == {:error, :not_allowed}
    end

    test "accepts an exact host and refuses one that is not listed" do
      put_config(%{source_allowlist: ["media.example"]})

      assert Https.authorize({:http, "https://media.example/a.wav"}) == :ok
      assert Https.authorize({:http, "https://other.example/a.wav"}) == {:error, :not_allowed}
    end

    test "folds case, as DNS does" do
      put_config(%{source_allowlist: ["Media.Example"]})

      assert {:ok, source} = parse("https://MEDIA.example/a.wav")
      assert Https.authorize(source) == :ok
    end

    test "a leading-*. entry is anchored to a label boundary" do
      put_config(%{source_allowlist: ["*.media.example"]})

      assert Https.authorize({:http, "https://media.example/a.wav"}) == :ok
      assert Https.authorize({:http, "https://cdn.media.example/a.wav"}) == :ok
      assert Https.authorize({:http, "https://a.b.media.example/a.wav"}) == :ok

      assert Https.authorize({:http, "https://media.example.evil.com/a.wav"}) ==
               {:error, :not_allowed}

      assert Https.authorize({:http, "https://notmedia.example/a.wav"}) == {:error, :not_allowed}
    end

    test "a host prefix glob is not a pattern, so it admits nothing" do
      put_config(%{source_allowlist: ["cdn.*"]})

      assert Https.authorize({:http, "https://cdn.evil.com/a.wav"}) == {:error, :not_allowed}
      assert Https.authorize({:http, "https://cdn.media.example/a.wav"}) == {:error, :not_allowed}
      # Not even the literal it was typed as.
      assert Https.authorize({:http, "https://cdn./a.wav"}) == {:error, :not_allowed}
    end

    test "a bare * admits everything" do
      put_config(%{source_allowlist: ["*"]})

      assert Https.authorize({:http, "https://anything.example/a.wav"}) == :ok
    end

    test "an IP-literal host is matched bracketless" do
      put_config(%{source_allowlist: ["::1"]})

      assert {:ok, source} = parse("https://[0:0:0:0:0:0:0:1]/a.wav")
      assert Source.canonical(source) == "https://[::1]/a.wav"
      assert Https.authorize(source) == :ok

      put_config(%{source_allowlist: ["[::1]"]})
      assert Https.authorize(source) == {:error, :not_allowed}
    end

    test "returns a verdict for a hand-built source rather than raising" do
      put_config(%{source_allowlist: ["media.example"]})

      # Every one of these would raise out of `URI.new!/1` or a bare match.
      assert Https.authorize({:http, "https://[/a.wav"}) == {:error, :not_allowed}
      assert Https.authorize({:http, "not a url at all"}) == {:error, :not_allowed}
      assert Https.authorize({:http, ""}) == {:error, :not_allowed}
      assert Https.authorize({:http, nil}) == {:error, :not_allowed}
      assert Https.authorize({:http}) == {:error, :not_allowed}
      assert Https.authorize({:http, "https:///a.wav"}) == {:error, :not_allowed}
    end

    test "refuses a hand-built source whose host the parser would have rejected" do
      # The gate runs the same normalization and validation the parser does, so
      # the two cannot reach different answers about which host a URL names.
      put_config(%{source_allowlist: ["*"]})

      for url <- [
            "https:///a.wav",
            "https://./a.wav",
            "https://.../a.wav",
            "https://cdn..media.example/a.wav",
            "https://%6D%65dia.example/a.wav"
          ] do
        assert Https.authorize({:http, url}) == {:error, :not_allowed},
               "expected #{url} to be refused even under a bare *"
      end
    end

    test "refuses a hand-built source carrying credentials" do
      # `parse/1` refuses userinfo, but a tuple built by hand would otherwise
      # walk credentials past the one function whose job is to say no.
      put_config(%{source_allowlist: ["media.example"]})

      assert Https.authorize({:http, "https://user:pass@media.example/a.wav"}) ==
               {:error, :not_allowed}
    end

    test "a trailing root dot in a hand-built URL still matches its entry" do
      put_config(%{source_allowlist: ["media.example"]})

      assert Https.authorize({:http, "https://media.example./a.wav"}) == :ok
    end
  end

  describe "the storage seam" do
    test "reports that no backend has shipped yet, rather than crashing" do
      source = {:http, "https://media.example/a.wav"}

      assert Https.stat(source) == {:error, :no_backend}
      assert Https.ffmpeg_input(source) == {:error, :no_backend}
    end
  end
end
