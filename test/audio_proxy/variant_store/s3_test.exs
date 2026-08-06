defmodule AudioProxy.VariantStore.S3Test do
  @moduledoc """
  What is specific to the `s3://` backend, and so is not in the parity suite:
  where the metadata lands on the object, what an object nobody here wrote
  reads as, and how a store that fails a lookup is reported.

  The seam's own surface — round trips, ranges, misses, aborted writes — is
  `AudioProxy.VariantStore.ParityS3Test`, which runs the identical assertions
  against `file://`.

  Tagged `:minio`; see `docs/development.md`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AudioProxy.{Config, MinioHelper, S3, VariantStore}

  @moduletag :minio
  @moduletag timeout: 120_000

  @bucket "audio-proxy-variants"

  @metadata %{
    content_type: "audio/ogg",
    cache_control: "public, max-age=31536000, immutable",
    etag: ~s("0123abcd")
  }

  setup do
    MinioHelper.configure!(%{variant_store: {:s3, @bucket}, serve_mode: :proxy})
    MinioHelper.ensure_bucket!(@bucket)
    :ok
  end

  defp key do
    :sha256
    |> :crypto.hash("#{System.unique_integer([:positive, :monotonic])}#{System.os_time()}")
    |> Base.encode16(case: :lower)
  end

  describe "capabilities" do
    test "the backend advertises presigning, which is what makes redirect mode reachable" do
      assert VariantStore.capabilities() == [:presign]
    end
  end

  describe "metadata on the object" do
    test "content type and cache-control are the object's own headers, not a sidecar" do
      # The load-bearing one for redirect mode: the client fetches the object
      # with no proxy in the path, so whatever it receives here is what it gets.
      key = key()
      :ok = VariantStore.put_stream(key, ["OggS…"], @metadata)

      assert {:ok, url} = VariantStore.presign(key, expires_in: 60)
      assert {200, headers, "OggS…"} = MinioHelper.fetch(url)

      assert headers["content-type"] == "audio/ogg"
      assert headers["cache-control"] == "public, max-age=31536000, immutable"
    end

    test "the seam's etag rides as user metadata, since S3 computes its own" do
      key = key()
      :ok = VariantStore.put_stream(key, ["bytes"], @metadata)

      assert {:ok, object} = S3.head(@bucket, key)
      assert object.metadata["etag"] == ~s("0123abcd")
      # And the object's own ETag is S3's, which is *not* what the seam serves.
      refute object.etag == ~s("0123abcd")

      assert {:ok, %{metadata: %{etag: ~s("0123abcd")}}} = VariantStore.head(key)
    end

    test "an object without the variant metadata is a miss, not a variant" do
      # A 64-hex object that this module did not write — a stray copy, another
      # tool's upload. Serving it would mean inventing the headers a redirect
      # cannot correct, so it reads as absent.
      key = key()
      :ok = S3.put_stream(@bucket, key, ["not a variant"])

      assert {:error, :not_found} = VariantStore.head(key)
    end
  end

  describe "presigning" do
    test "a presigned URL fetches the variant's bytes" do
      key = key()
      :ok = VariantStore.put_stream(key, ["redirect me"], @metadata)

      assert {:ok, url} = VariantStore.presign(key, expires_in: 60)
      assert {200, _headers, "redirect me"} = MinioHelper.fetch(url)
    end

    test "the requested TTL reaches the signature" do
      key = key()
      :ok = VariantStore.put_stream(key, ["bytes"], @metadata)

      assert {:ok, url} = VariantStore.presign(key, expires_in: 42)
      assert URI.decode_query(URI.parse(url).query)["X-Amz-Expires"] == "42"
    end

    test "AP_PRESIGN_TTL is the default when no expiry is given" do
      key = key()
      :ok = VariantStore.put_stream(key, ["bytes"], @metadata)

      assert {:ok, url} = VariantStore.presign(key, [])
      assert URI.decode_query(URI.parse(url).query)["X-Amz-Expires"] == "900"
    end
  end

  describe "failures are misses, loudly" do
    setup do
      AudioProxy.ConfigHelper.put_config(%{
        s3: %{Config.get(:s3) | access_key_id: nil, secret_access_key: nil}
      })

      :ok
    end

    test "a store that cannot be asked answers a miss, so the request renders" do
      log = capture_log(fn -> assert {:error, :not_found} = VariantStore.head(key()) end)

      # Loudly, though: "every request is a MISS" is not a symptom an operator
      # can debug from the outside, so the reason and its classification are in
      # the log even though the caller only ever hears "not found".
      assert log =~ "s3 variant store"
      assert log =~ "treating as a miss"
      assert log =~ ":not_configured"
    end

    test "a read that cannot be attempted is a miss too" do
      log =
        capture_log(fn -> assert {:error, :not_found} = VariantStore.get_stream(key(), nil) end)

      assert log =~ "treating as a miss"
    end
  end

  describe "the boot probe" do
    test "a writable bucket boots, and the probe object does not survive it" do
      before = probe_objects()

      assert %{variant_store: {:s3, @bucket}} = Config.load!(env())
      assert probe_objects() == before
    end

    test "a bucket that is not there fails the container, naming the variable" do
      error =
        assert_raise Config.Error, fn ->
          Config.load!(%{env() | "AP_VARIANT_STORE" => "s3://no-such-bucket-here"})
        end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "boot probe"
    end

    test "an s3:// store with no credentials fails the container, naming them" do
      error =
        assert_raise Config.Error, fn ->
          Config.load!(Map.drop(env(), ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]))
        end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "AWS_ACCESS_KEY_ID"
    end
  end

  ## Fixture

  defp env do
    %{
      "AP_VARIANT_STORE" => "s3://#{@bucket}",
      "AP_S3_ENDPOINT" => URI.to_string(MinioHelper.endpoint()),
      "AWS_ACCESS_KEY_ID" => "minioadmin",
      "AWS_SECRET_ACCESS_KEY" => "minioadmin",
      "AWS_REGION" => "us-east-1"
    }
  end

  # Everything under the reserved prefix, which after a successful boot is
  # nothing: the probe deletes what it wrote.
  defp probe_objects do
    {:ok, %{body: %{contents: contents}}} =
      @bucket
      |> ExAws.S3.list_objects_v2(prefix: ".audio-proxy-boot-probe/")
      |> ExAws.request(S3.config())

    Enum.map(contents, & &1.key)
  end
end
