defmodule AudioProxy.ExpiryTest do
  @moduledoc """
  The verdict and the two clamps as pure functions — the boundary cases the
  end-to-end suite cannot pin, because it cannot say what second it is.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.{Expiry, Options}

  doctest AudioProxy.Expiry

  @variant "public, max-age=31536000, immutable, no-transform"

  defp options(expires_at), do: %Options{expires_at: expires_at}

  defp now, do: System.system_time(:second)

  describe "the verdict" do
    test "options carrying no exp never expire" do
      assert Expiry.check(%Options{}) == :ok
      assert Expiry.remaining(%Options{}) == :infinity
    end

    test "the expiring second is still served" do
      # `now > exp`, not `>=`: a URL stamped for this second was asked for
      # within the second it names, and a generator that wrote `exp:now+60`
      # promised sixty seconds rather than fifty-nine.
      assert Expiry.check(options(now())) == :ok
      assert Expiry.check(options(now() - 1)) == {:error, :expired}
    end

    test "remaining never goes negative" do
      assert Expiry.remaining(options(now() - 10_000)) == 0
    end
  end

  describe "the cache-control clamp" do
    test "lowers a max-age that outlives the URL and leaves the rest alone" do
      clamped = Expiry.clamp_cache_control(@variant, options(now() + 60))

      assert clamped =~ ~r/^public, max-age=(59|60), immutable, no-transform$/
    end

    test "never raises a max-age that is already shorter" do
      # The configured policy is a ceiling, not a target: `exp` an hour out must
      # not turn a ten-second error TTL into an hour of it.
      assert Expiry.clamp_cache_control("max-age=10", options(now() + 3600)) == "max-age=10"
    end

    test "a header with no max-age is untouched" do
      assert Expiry.clamp_cache_control("no-store", options(now() + 60)) == "no-store"
    end

    test "without exp the header is returned byte for byte" do
      assert Expiry.clamp_cache_control(@variant, %Options{}) == @variant
    end

    test "an already-expired URL clamps to zero rather than to a negative age" do
      assert Expiry.clamp_cache_control(@variant, options(now() - 10)) ==
               "public, max-age=0, immutable, no-transform"
    end
  end

  describe "the ttl clamp" do
    test "takes the lower of the configured ttl and what is left" do
      assert Expiry.clamp_ttl(3600, options(now() + 30)) in 29..30
      assert Expiry.clamp_ttl(10, options(now() + 3600)) == 10
    end

    test "without exp the configured ttl is untouched" do
      # `:infinity` sorts above every integer, so `min/2` needs no special case
      # — but the behaviour is what deployments without `exp` rely on, so it is
      # asserted rather than left to term ordering.
      assert Expiry.clamp_ttl(300, %Options{}) == 300
    end
  end
end
