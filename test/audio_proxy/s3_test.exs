defmodule AudioProxy.S3Test do
  @moduledoc """
  `AudioProxy.S3` against a real S3-compatible store.

  There is no fake here and there deliberately isn't one. A stub cannot
  verify a signature, so it cannot tell a correct request from a
  self-consistently wrong one — and since `ex_aws` builds the requests, what
  is actually under test is *our* half: the config overrides, the endpoint
  and addressing decision, the error translation, the metadata round trip,
  and the ranged read assembled on top of `get_object`.

  Those are exactly the things a stub would agree with us about and a store
  will not.

  Tagged `:minio`, excluded by default, and it fails rather than skips when
  the store is missing — a green run against nothing is a lie about coverage.
  See `docs/development.md`.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.S3

  @moduletag :minio
  @moduletag timeout: 120_000

  @bucket "audio-proxy-test"

  setup_all do
    endpoint = URI.parse(System.get_env("AP_TEST_MINIO_ENDPOINT", "http://minio:9000"))

    ensure_reachable!(endpoint)
    {:ok, endpoint: endpoint}
  end

  setup %{endpoint: endpoint} do
    put_config(%{
      presign_ttl: 900,
      s3: %{
        region: "us-east-1",
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        session_token: nil,
        endpoint: endpoint
      }
    })

    ensure_bucket!()
    :ok
  end

  describe "head/2" do
    test "reports size and ETag for an object that is there" do
      key = unique_key("head.bin")
      :ok = S3.put_stream(@bucket, key, ["0123456789"])

      assert {:ok, object} = S3.head(@bucket, key)
      assert object.size == 10
      assert object.etag =~ ~r/^"?[0-9a-f]{32}(-\d+)?"?$/
    end

    test "a missing key is :not_found" do
      assert S3.head(@bucket, unique_key("absent.bin")) == {:error, :not_found}
    end

    test "a HEAD cannot tell a missing bucket from a missing object" do
      # Pinned rather than left as folklore: a HEAD response carries no body,
      # so the `NoSuchBucket` code that distinguishes the two is not on the
      # wire at all. A misconfigured bucket therefore reads as a cache miss
      # on this path — the write path below is where it actually surfaces.
      assert S3.head("no-such-bucket-#{System.unique_integer([:positive])}", "k") ==
               {:error, :not_found}
    end

    test "a write to a missing bucket is not reported as a miss" do
      # Here the error body exists, so folding it into :not_found would make
      # a misconfigured AP_VARIANT_STORE look like a permanently cold cache:
      # every write silently failing, every read a miss, every miss a
      # re-render.
      bucket = "no-such-bucket-#{System.unique_integer([:positive])}"

      assert {:error, {:http, 404, body}} = S3.put_stream(bucket, "k.bin", ["x"])
      assert body =~ "NoSuchBucket"
    end

    test "bad credentials are :access_denied, not :not_found" do
      # Folding these together would turn an expired credential into a
      # permanently cold cache: every request a miss, every miss a re-render.
      put_config(%{s3: %{AudioProxy.Config.get(:s3) | secret_access_key: "wrong-secret"}})

      assert S3.head(@bucket, "anything.bin") == {:error, :access_denied}
    end
  end

  describe "put_stream/4" do
    test "a short stream round-trips byte-for-byte" do
      key = unique_key("short.bin")
      :ok = S3.put_stream(@bucket, key, ["hello ", "world"])

      assert read(key) == "hello world"
    end

    test "a multi-part stream round-trips byte-for-byte" do
      # Over the 5 MiB minimum part size, so ex_aws genuinely runs the
      # multipart protocol and MinIO has to reassemble it.
      key = unique_key("multipart.bin")
      chunks = for index <- 1..150, do: :binary.copy(<<rem(index, 256)>>, 64_000)
      expected = IO.iodata_to_binary(chunks)

      assert byte_size(expected) > 5 * 1024 * 1024
      assert :ok = S3.put_stream(@bucket, key, chunks)

      assert {:ok, %{size: size}} = S3.head(@bucket, key)
      assert size == byte_size(expected)
      assert read(key) == expected
    end

    test "content type, cache control and metadata survive the round trip" do
      key = unique_key("meta.bin")

      :ok =
        S3.put_stream(@bucket, key, ["x"],
          content_type: "audio/mpeg",
          cache_control: "public, max-age=31536000, immutable",
          metadata: %{"etag" => ~s("cachekey")}
        )

      assert {:ok, object} = S3.head(@bucket, key)
      assert object.content_type == "audio/mpeg"
      assert object.cache_control == "public, max-age=31536000, immutable"
      assert object.metadata["etag"] == ~s("cachekey")
    end

    test "metadata survives a multipart write too" do
      # It rides on the initiate request, not the parts — a different code
      # path in ex_aws than the single-shot put above.
      key = unique_key("multipart-meta.bin")
      chunks = for _ <- 1..150, do: :binary.copy("a", 64_000)

      :ok =
        S3.put_stream(@bucket, key, chunks,
          content_type: "audio/mpeg",
          metadata: %{"etag" => ~s("cachekey")}
        )

      assert {:ok, object} = S3.head(@bucket, key)
      assert object.content_type == "audio/mpeg"
      assert object.metadata["etag"] == ~s("cachekey")
    end

    test "a stream that raises leaves no object behind" do
      # The tee's cancellation signal. ex_aws aborts the multipart upload on
      # its way out, so nothing is readable and no parts accrue.
      key = unique_key("aborted.bin")

      chunks =
        Stream.concat(
          for(_ <- 1..150, do: :binary.copy("a", 64_000)),
          Stream.map([:boom], fn _ -> raise "render cancelled" end)
        )

      assert {:error, %RuntimeError{}} = S3.put_stream(@bucket, key, chunks)
      assert S3.head(@bucket, key) == {:error, :not_found}
    end

    test "an empty stream still writes an object" do
      key = unique_key("empty.bin")

      assert :ok = S3.put_stream(@bucket, key, [])
      assert {:ok, %{size: 0}} = S3.head(@bucket, key)
    end
  end

  describe "get_stream/3" do
    setup do
      key = unique_key("read.bin")
      :ok = S3.put_stream(@bucket, key, ["0123456789"])
      {:ok, key: key}
    end

    test "the whole object, in order", %{key: key} do
      assert read(key) == "0123456789"
    end

    test "an interior range is exactly those bytes", %{key: key} do
      assert read(key, {2, 5}) == "2345"
    end

    test "a single-byte range", %{key: key} do
      assert read(key, {4, 4}) == "4"
    end

    test "the final byte is reachable", %{key: key} do
      assert read(key, {9, 9}) == "9"
    end

    test "a missing object is an error, not an empty stream" do
      assert S3.get_stream(@bucket, unique_key("absent.bin")) == {:error, :not_found}
    end

    test "a zero-length object streams as nothing" do
      key = unique_key("empty-read.bin")
      :ok = S3.put_stream(@bucket, key, [])

      assert read(key) == ""
    end

    test "a large object comes back in bounded chunks, byte-identical" do
      # Bigger than the 1 MiB read chunk, so the ranged-GET assembly is
      # genuinely exercised rather than collapsing into one request.
      key = unique_key("large.bin")
      bytes = :crypto.strong_rand_bytes(2_500_000)
      :ok = S3.put_stream(@bucket, key, [bytes])

      {:ok, stream} = S3.get_stream(@bucket, key)
      chunks = Enum.to_list(stream)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1) <= 1_048_576))
      assert IO.iodata_to_binary(chunks) == bytes
    end
  end

  describe "presign_get/3" do
    test "a presigned URL fetches the object" do
      key = unique_key("presign.bin")
      :ok = S3.put_stream(@bucket, key, ["presigned bytes"])

      assert {:ok, url} = S3.presign_get(@bucket, key)
      assert {200, "presigned bytes"} = fetch(url)
    end

    test "an unsigned URL is rejected — the bucket is not public" do
      # Without this, every presign test could be passing against an open
      # bucket and proving nothing about the signature.
      key = unique_key("unsigned.bin")
      :ok = S3.put_stream(@bucket, key, ["secret"])

      endpoint = AudioProxy.Config.get(:s3).endpoint
      {status, _body} = fetch(URI.to_string(%{endpoint | path: "/#{@bucket}/#{key}"}))

      assert status in [401, 403]
    end

    test "a tampered signature is rejected" do
      key = unique_key("tampered.bin")
      :ok = S3.put_stream(@bucket, key, ["secret"])

      {:ok, url} = S3.presign_get(@bucket, key)

      assert {403, _body} = fetch(String.replace(url, ~r/X-Amz-Signature=./, "X-Amz-Signature=0"))
    end

    test "an expired URL is rejected by the store" do
      key = unique_key("expired.bin")
      :ok = S3.put_stream(@bucket, key, ["secret"])

      {:ok, url} = S3.presign_get(@bucket, key, expires_in: 1)
      Process.sleep(1_500)

      assert {403, _body} = fetch(url)
    end

    test "the expiry override wins over AP_PRESIGN_TTL" do
      {:ok, url} = S3.presign_get(@bucket, "k.bin", expires_in: 60)

      assert URI.decode_query(URI.parse(url).query)["X-Amz-Expires"] == "60"
    end

    test "keys with spaces, +, and unicode fetch the object they name" do
      # The escaping cases, against a store that decodes the path for real.
      for name <- ["a b.bin", "a+b.bin", "für-elise.bin", "2026/take 3.bin"] do
        key = unique_key(name)
        :ok = S3.put_stream(@bucket, key, [key])

        {:ok, url} = S3.presign_get(@bucket, key)

        assert {200, ^key} = fetch(url), "presigned GET failed for #{inspect(key)}"
      end
    end

    test "keys differing only in escaping are different objects" do
      # `a b` and `a%20b` are two objects in S3. Folding them would hand two
      # variants one cache entry.
      space = unique_key("collide a b.bin")
      escaped = String.replace(space, " ", "%20")

      :ok = S3.put_stream(@bucket, space, ["spaced"])
      :ok = S3.put_stream(@bucket, escaped, ["escaped"])

      {:ok, space_url} = S3.presign_get(@bucket, space)
      {:ok, escaped_url} = S3.presign_get(@bucket, escaped)

      assert {200, "spaced"} = fetch(space_url)
      assert {200, "escaped"} = fetch(escaped_url)
    end
  end

  describe "config/0" do
    test "a custom endpoint switches to path-style addressing", %{endpoint: endpoint} do
      config = S3.config()

      assert config[:host] == endpoint.host
      assert config[:port] == endpoint.port
      assert config[:scheme] == endpoint.scheme <> "://"
    end

    test "no endpoint means AWS proper, and ex_aws's own defaults" do
      put_config(%{s3: %{AudioProxy.Config.get(:s3) | endpoint: nil}})

      config = S3.config()

      refute Keyword.has_key?(config, :host)
      assert config[:region] == "us-east-1"
    end
  end

  ## Fixture

  defp read(key, range \\ nil) do
    assert {:ok, stream} = S3.get_stream(@bucket, key, range)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp ensure_bucket! do
    # 200 the first time, and ex_aws reports the already-owned case as an
    # error we can ignore.
    @bucket |> ExAws.S3.put_bucket("us-east-1") |> ExAws.request(S3.config())

    :ok
  end

  # `:httpc` directly, which is also what `AudioProxy.S3.HttpClient` drives —
  # so a fetch here is the same stack the proxy uses, minus the signing.
  defp ensure_reachable!(endpoint) do
    url = URI.to_string(%{endpoint | path: "/minio/health/live"})

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [connect_timeout: 2_000, timeout: 5_000],
           []
         ) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        :ok

      other ->
        raise """
        MinIO is not reachable at #{URI.to_string(endpoint)} (#{inspect(other)}).

        These tests are tagged :minio and excluded by default; running them
        requires a store. See docs/development.md, or set
        AP_TEST_MINIO_ENDPOINT.
        """
    end
  end

  defp fetch(url) do
    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    {status, body}
  end

  # Unique per run, so a rerun never reads an object a previous one wrote and
  # the suite needs no teardown.
  defp unique_key(name), do: "#{System.unique_integer([:positive])}/#{name}"
end
