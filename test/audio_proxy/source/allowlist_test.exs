defmodule AudioProxy.Source.AllowlistTest do
  @moduledoc """
  The grammar on its own. `matches?/3` is the matcher without the config read,
  so the pattern rules are pinned here and the per-type suites test the policy
  that wraps them.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Source.Allowlist

  describe "matches?/3 for buckets" do
    test "an exact name, case-sensitively — as S3 is" do
      assert Allowlist.matches?(:bucket, "masters", "masters")
      refute Allowlist.matches?(:bucket, "masters", "Masters")
      refute Allowlist.matches?(:bucket, "masters", "masters-eu")
    end

    test "a trailing * is a prefix glob" do
      assert Allowlist.matches?(:bucket, "previews-*", "previews-eu")
      assert Allowlist.matches?(:bucket, "previews-*", "previews-")
      refute Allowlist.matches?(:bucket, "previews-*", "eu-previews")
      refute Allowlist.matches?(:bucket, "previews-*", "Previews-eu")
    end

    test "a bare * is everything" do
      assert Allowlist.matches?(:bucket, "*", "anything")
    end

    test "a * anywhere else matches nothing, not even loosely" do
      for pattern <- ["*masters", "mas*ters", "*masters*", "mas**", "**"] do
        for bucket <- ["masters", "masters-eu", "eu-masters", "mas", ""] do
          refute Allowlist.matches?(:bucket, pattern, bucket),
                 "expected #{pattern} not to admit #{inspect(bucket)}"
        end
      end
    end
  end

  describe "matches?/3 for hosts" do
    test "an exact name, case-folded — as DNS is" do
      assert Allowlist.matches?(:host, "media.example", "media.example")
      assert Allowlist.matches?(:host, "Media.Example", "media.example")
      refute Allowlist.matches?(:host, "media.example", "cdn.media.example")
    end

    test "a leading *. is a label-anchored suffix glob" do
      assert Allowlist.matches?(:host, "*.media.example", "media.example")
      assert Allowlist.matches?(:host, "*.media.example", "cdn.media.example")
      assert Allowlist.matches?(:host, "*.media.example", "eu.cdn.media.example")
      assert Allowlist.matches?(:host, "*.Media.Example", "cdn.media.example")

      refute Allowlist.matches?(:host, "*.media.example", "media.example.evil.com")
      refute Allowlist.matches?(:host, "*.media.example", "xmedia.example")
      refute Allowlist.matches?(:host, "*.media.example", "example")
    end

    test "a host prefix glob is not a pattern — the footgun this forecloses" do
      refute Allowlist.matches?(:host, "cdn.*", "cdn.evil.com")
      refute Allowlist.matches?(:host, "cdn.*", "cdn.media.example")
      # Not even the literal it was typed as.
      refute Allowlist.matches?(:host, "cdn.*", "cdn.*")
    end

    test "a * anywhere but the leading label matches nothing" do
      for pattern <- ["media.*.example", "*media.example", "*.*", "*.", "**.media.example"] do
        for host <- ["media.example", "cdn.media.example", "evil.com"] do
          refute Allowlist.matches?(:host, pattern, host),
                 "expected #{pattern} not to admit #{host}"
        end
      end
    end

    test "an operator's trailing root dot is normalized away, like the subject's" do
      assert Allowlist.matches?(:host, "media.example.", "media.example")
      assert Allowlist.matches?(:host, "*.media.example.", "cdn.media.example")
    end

    test "an IP literal is matched bracketless" do
      assert Allowlist.matches?(:host, "::1", "::1")
      refute Allowlist.matches?(:host, "[::1]", "::1")
    end
  end

  describe "matches?/3 on input it was never meant to get" do
    test "answers false rather than raising" do
      # The module's contract is that it answers. That has to hold for the
      # whole module, not just for `authorize/2`.
      for pattern <- [nil, 42, :masters, ["masters"]] do
        refute Allowlist.matches?(:bucket, pattern, "masters")
        refute Allowlist.matches?(:host, pattern, "media.example")
      end

      refute Allowlist.matches?(:host, "media.example", nil)
      refute Allowlist.matches?(:bucket, "masters", 42)
    end
  end

  describe "authorize/2" do
    test "refuses anything that is not a non-empty binary, rather than interpreting it" do
      for subject <- [nil, 42, "", :media, {:http, "x"}] do
        assert Allowlist.authorize(:host, subject) == {:error, :not_allowed}
        assert Allowlist.authorize(:bucket, subject) == {:error, :not_allowed}
      end
    end
  end
end
