defmodule AudioProxy.Source.RemoteRegressionTest do
  @moduledoc """
  The defects adversarial review found in these two source forms, each pinned
  by the case that exposed it — five from the first implementation, and the
  host-validation family from the review of this slice.

  This file earns its overlap with the per-type suites. Those tests state what
  the spec requires; these state what was once *wrong*, so a refactor that
  reintroduces one fails against a test that names it rather than against a
  line someone has to reconstruct the reasoning for.
  """

  # The allowlist lives in `:persistent_term`, which is global.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import AudioProxy.ConfigHelper

  alias AudioProxy.Source
  alias AudioProxy.Source.{Allowlist, Https}

  # Hostile host spellings: the dots and empty labels that broke this once, plus
  # ordinary labels and an IP literal so the property is not all rejections.
  @host_parts ["a", "media", "example", ".", "..", "", "-", "1", "2001:db8::1", "%2E"]

  property "a source that parses is a source the gate agrees with" do
    # The invariant behind the whole host-validation family: `parse/1` and
    # `authorize/1` must never disagree about which host a URL names. Under a
    # bare `*` every host is allowlisted, so anything that parses must
    # authorize — and anything the gate refuses under `*` is a host the parser
    # should not have accepted. `https://../a` broke exactly this: it parsed to
    # the host `.` and its canonical URL re-parsed to the empty string.
    put_config(%{source_allowlist: ["*"]})

    check all(
            parts <- list_of(member_of(@host_parts), min_length: 1, max_length: 4),
            separator <- member_of([".", ""])
          ) do
      host = Enum.join(parts, separator)

      case Source.parse("plain/https://" <> host <> "/a.wav") do
        {:ok, source} ->
          assert Https.authorize(source) == :ok,
                 "parse accepted #{inspect(host)} but the gate refused it"

          # And the canonical string it produced is one the parser accepts back,
          # unchanged — canonicalization has to be a fixed point.
          assert Source.parse("plain/" <> Source.canonical(source)) == {:ok, source}

        {:error, _refused} ->
          :ok
      end
    end
  end

  test "an empty label is refused rather than admitted by a *. entry" do
    # `*.media.example` admitted every one of these, each with its own canonical
    # string: one origin resource, unboundedly many allowlisted cache keys.
    put_config(%{source_allowlist: ["*.media.example"]})

    for host <- [".media.example", "cdn..media.example", "..media.example"] do
      assert Source.parse("plain/https://" <> host <> "/a.wav") == {:error, :invalid_url},
             "expected #{host} to be refused"
    end

    assert {:ok, source} = Source.parse("plain/https://cdn.media.example/a.wav")
    assert Https.authorize(source) == :ok
  end

  test "a dot-only host never becomes a hostless canonical URL" do
    # `https://./a` normalized to "" and rendered `https:///a` — a cache key for
    # a string that is not a URL.
    for host <- [".", "..", "..."] do
      assert Source.parse("plain/https://" <> host <> "/a.wav") == {:error, :invalid_url},
             "expected #{inspect(host)} to be refused"
    end
  end

  test "the s3 body is bounded before it is split, not after" do
    # `String.split/3` scans a separator-free body in full; the bound has to
    # come first. Cheap here (0.177 ms for 10 MB), but the ordering is the
    # invariant, and `tasks.md` 1.2a asked for it explicitly.
    assert Source.parse("plain/s3://" <> String.duplicate("a", 100_000)) ==
             {:error, :source_too_long}
  end

  test "a Unicode control in a URL is refused, not carried into the canonical string" do
    # `\x00-\x1f` alone lets all of these through, and each one reaches ffmpeg
    # argv, an object key, a `Content-Disposition` and a log line. U+202E is
    # the filename-spoofing one.
    for code_point <- ["\u0000", "\u001f", "\u0085", "\u2028", "\u202E", "\u200B"] do
      source = "https://media.example/a" <> code_point <> "b.wav"
      encoded = "enc/" <> Base.url_encode64(source, padding: false)

      assert Source.parse(encoded) == {:error, :control_character},
             "expected #{inspect(code_point)} to be refused"
    end
  end

  test "a host prefix glob admits nothing, rather than any registrable suffix" do
    # `cdn.*` reads as "our CDN" and would mean "any host starting `cdn.`".
    put_config(%{source_allowlist: ["cdn.*"]})

    for host <- ["cdn.evil.com", "cdn.media.example", "cdn.", "cdn.a"] do
      assert Https.authorize({:http, "https://" <> host <> "/a.wav"}) ==
               {:error, :not_allowed},
             "expected #{host} to be refused"
    end

    # The same `*` in the position buckets document is a pattern; in the host
    # grammar it is not, and "not a pattern" means no match, not a loose one.
    assert Allowlist.matches?(:bucket, "cdn-*", "cdn-eu")
    refute Allowlist.matches?(:host, "cdn.*", "cdn.evil.com")
  end

  test "authorize/1 returns a verdict on a hand-built tuple instead of raising" do
    # A security gate that raises is a security gate that answers 500. Every
    # one of these would have come out of `URI.new!/1` or a bare match.
    put_config(%{source_allowlist: ["media.example"]})

    for url <- ["https://[/a.wav", "https://media.example:notaport/a", "", "://", nil, 42] do
      assert Https.authorize({:http, url}) == {:error, :not_allowed},
             "expected #{inspect(url)} to be refused"
    end

    assert Https.authorize({:http}) == {:error, :not_allowed}
    assert Https.authorize(:not_a_source) == {:error, :not_allowed}
  end

  test "a trailing root dot, an explicit :443 and an empty query all fold away" do
    # Each survived canonicalization once, and each one buys one object a
    # second cache key.
    canonical = "https://media.example/a.wav"

    for spelling <- [
          "https://media.example./a.wav",
          "https://media.example:443/a.wav",
          "https://media.example/a.wav?",
          "https://media.example./a.wav#",
          "https://MEDIA.EXAMPLE.:443/a.wav?"
        ] do
      assert {:ok, source} = Source.parse("plain/" <> spelling)
      assert Source.canonical(source) == canonical, "expected #{spelling} to fold"
    end
  end

  test "an IPv6 literal folds by address, and the canonical URL keeps its brackets" do
    assert {:ok, long} = Source.parse("plain/https://[2001:0db8:0000:0000:0000:0000:0000:0001]/a")
    assert {:ok, short} = Source.parse("plain/https://[2001:db8::1]/a")

    assert long == short
    assert Source.canonical(long) == "https://[2001:db8::1]/a"

    # Matched bracketless, which is the form `URI` yields — documented, because
    # the canonical URL shows the brackets and the mismatch fails closed.
    put_config(%{source_allowlist: ["2001:db8::1"]})
    assert Https.authorize(long) == :ok
  end

  test "inet_aton shorthand is not folded, so it cannot inherit an allowlist entry" do
    # The lenient parser reads `01.2.3.4` as 1.2.3.4 and `1.2` as 1.0.0.2.
    # `:inet.parse_strict_address/1` reads neither, so they stay text — which
    # is what keeps them distinct subjects.
    put_config(%{source_allowlist: ["1.2.3.4"]})

    for shorthand <- ["01.2.3.4", "1.2", "0x1.2.3.4"] do
      assert {:ok, source} = Source.parse("plain/https://" <> shorthand <> "/a.wav")

      assert Source.canonical(source) == "https://" <> shorthand <> "/a.wav"

      assert Https.authorize(source) == {:error, :not_allowed},
             "expected #{shorthand} not to inherit the entry for 1.2.3.4"
    end

    # The one exception is the root dot, which is not shorthand for a different
    # address — it is a second spelling of the same one.
    assert {:ok, dotted} = Source.parse("plain/https://1.2.3.4./a.wav")
    assert Source.canonical(dotted) == "https://1.2.3.4/a.wav"
    assert Https.authorize(dotted) == :ok
  end
end
