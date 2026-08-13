defmodule AudioProxy.S3ProfilesTest do
  @moduledoc """
  Which configuration each S3 operation runs under.

  Storeless and untagged, for the reason `AudioProxy.S3AddressingTest` gives:
  a presigned URL is pure local computation, so the profile a signature was
  built from is visible in the URL's bytes without anything being reachable.
  That is the assertion that matters here — the host and the access key id are
  both inside a SigV4 signature, so a HIT signed with the wrong profile is not
  a URL that works less well, it is one no store can verify.

  The round trips against two real endpoints are
  `AudioProxy.VariantStore.ParityS3Test`'s and `AudioProxy.S3SplitStoreTest`'s;
  what cannot be reached from CI is pinned here instead.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.S3
  alias AudioProxy.VariantStore

  @bucket "variants"
  @key String.duplicate("ab", 32)

  @source %{
    region: "eu-central-1",
    access_key_id: "SOURCEKEYEXAMPLE",
    secret_access_key: "source-secret",
    session_token: nil,
    endpoint: URI.parse("https://sources.example"),
    addressing: :path,
    ca_bundle: nil
  }

  @store %{
    region: "us-east-1",
    access_key_id: "STOREKEYEXAMPLE",
    secret_access_key: "store-secret",
    session_token: nil,
    endpoint: URI.parse("https://store.example"),
    addressing: :path,
    ca_bundle: nil
  }

  # The fixtures here install their profiles directly rather than through an
  # environment, so nothing in this file tests the `AP_VARIANT_S3_*` fallback —
  # that is `AudioProxy.ConfigTest`'s, from `AudioProxy.Config.build!/1`. What
  # is under test is the layer above it: which profile each operation reads.
  describe "with one profile" do
    setup do
      put_config(%{presign_ttl: 900, s3: @source})
      :ok
    end

    test "reading either profile yields the same overrides" do
      # Deliberately not the fallback assertion, which this cannot make: the
      # fixture installs one profile through `put_config/1`, and *that* is what
      # copies `:s3` into `:variant_s3` here. `AudioProxy.ConfigTest`'s "with
      # none of them set, the two profiles are the same map" is the honest one,
      # because it is built from `AudioProxy.Config.build!/1`.
      #
      # What this pins is the client layer: `config/1` reads the profile it was
      # given and nothing else, so equal profiles produce equal overrides down
      # to the keyword list `ex_aws` receives.
      assert S3.config(:store) == S3.config(:source)
    end

    test "config/0 still means the source profile" do
      assert S3.config() == S3.config(:source)
    end

    test "a presigned URL is the same URL under either profile" do
      assert signature_inputs(:source) == signature_inputs(:store)
    end

    test "both profiles are configured, or neither is" do
      assert S3.configured?(:source)
      assert S3.configured?(:store)

      put_config(%{s3: %{@source | access_key_id: nil}})

      refute S3.configured?(:source)
      refute S3.configured?(:store)
    end
  end

  describe "with two profiles" do
    setup do
      put_config(%{
        presign_ttl: 900,
        variant_store: {:s3, @bucket},
        s3: @source,
        variant_s3: @store
      })

      :ok
    end

    test "a store presign resolves against the store's endpoint and identity" do
      %{host: host, credential: credential} = signature_inputs(:store)

      assert host == "store.example"
      assert credential =~ "STOREKEYEXAMPLE"
      assert credential =~ "us-east-1"
    end

    test "a source presign is unaffected by the store's identity" do
      %{host: host, credential: credential} = signature_inputs(:source)

      assert host == "sources.example"
      assert credential =~ "SOURCEKEYEXAMPLE"
      assert credential =~ "eu-central-1"
    end

    test "the variant store backend signs a HIT with the store profile" do
      # The path an actual redirect takes, rather than the facade underneath
      # it: `AudioProxy.VariantStore.S3` is what decides which profile a
      # presigned HIT is built from, and getting it wrong is invisible until a
      # client follows the URL.
      assert {:ok, url} = VariantStore.S3.presign(@key, [])

      assert URI.parse(url).host == "store.example"
      assert URI.decode(url) =~ "STOREKEYEXAMPLE"
    end

    test "a store with no identity of its own is still not the source's" do
      # `configured?/1` is per profile, so a store profile whose credentials
      # were cleared refuses rather than quietly falling back at request time —
      # the fallback lives in `AudioProxy.Config`, once, at boot.
      put_config(%{variant_s3: %{@store | access_key_id: nil}})

      refute S3.configured?(:store)
      assert S3.configured?(:source)
      assert VariantStore.S3.presign(@key, []) == {:error, :not_configured}
    end
  end

  # The two parts of a presigned URL that carry the profile. The signature
  # itself is not compared: it covers a timestamp, so two calls a second apart
  # differ legitimately, while these do not.
  defp signature_inputs(profile) do
    assert {:ok, url} = S3.presign_get(@bucket, @key, [], profile)

    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")

    %{
      host: uri.host,
      path: uri.path,
      credential: Map.get(query, "X-Amz-Credential", "")
    }
  end
end
