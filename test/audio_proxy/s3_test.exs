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
        endpoint: endpoint,
        # MinIO is reached by hostname and port; `bucket.minio` would need DNS
        # nobody configured. Which is also why this file cannot cover
        # virtual-hosted addressing — see `AudioProxy.S3AddressingTest`.
        addressing: :path,
        ca_bundle: nil
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

    test "a stream that raises aborts the upload, leaving no object and no parts" do
      # The object being absent is the weak half of this: it is absent simply
      # because the upload was never completed. The load-bearing assertion is
      # that no *pending* upload remains — incomplete multipart uploads do not
      # show up in a bucket listing and are billed until something removes
      # them, which is exactly what ExAws.S3.upload/4 leaks.
      key = unique_key("aborted.bin")

      chunks =
        Stream.concat(
          for(_ <- 1..150, do: :binary.copy("a", 64_000)),
          Stream.map([:boom], fn _ -> raise "render cancelled" end)
        )

      assert {:error, %RuntimeError{}} = S3.put_stream(@bucket, key, chunks)
      assert S3.head(@bucket, key) == {:error, :not_found}
      assert pending_uploads(key) == []
    end

    test "a stream that exits aborts the upload, then keeps exiting" do
      # `exit` unwinds past `rescue` — a task timeout or a linked crash. The
      # exit is re-raised rather than swallowed, but not before the abort.
      key = unique_key("exited.bin")

      chunks =
        Stream.concat(
          for(_ <- 1..150, do: :binary.copy("a", 64_000)),
          Stream.map([:boom], fn _ -> exit(:render_cancelled) end)
        )

      assert catch_exit(S3.put_stream(@bucket, key, chunks)) == :render_cancelled
      assert pending_uploads(key) == []
    end

    test "a failing part aborts the upload" do
      # Bad credentials swapped in after the peek, so initiate succeeds and
      # the first part is rejected.
      key = unique_key("failed-part.bin")

      chunks =
        Stream.concat(
          for(_ <- 1..80, do: :binary.copy("a", 64_000)),
          Stream.map([:once], fn _ ->
            put_config(%{s3: %{AudioProxy.Config.get(:s3) | secret_access_key: "wrong"}})
            :binary.copy("b", 64_000)
          end)
        )

      assert {:error, _reason} = S3.put_stream(@bucket, key, chunks)
    end

    test "an object under one part goes as a single PutObject" do
      # S3's own ETag is the observable difference, which is what makes this
      # a test rather than a restatement of the code: a PutObject ETag is the
      # MD5 of the body, while a multipart ETag is a digest-of-digests with a
      # `-<parts>` suffix. Without the fast path this write would not merely
      # be slower — S3 rejects a sub-5-MiB multipart with EntityTooSmall.
      key = unique_key("under-one-part.bin")
      body = :binary.copy("a", 4 * 1024 * 1024)

      :ok = S3.put_stream(@bucket, key, [body])

      assert {:ok, %{etag: etag}} = S3.head(@bucket, key)
      assert etag == ~s("#{Base.encode16(:crypto.hash(:md5, body), case: :lower)}")
    end

    test "every part but the last is exactly the part size" do
      # Chunk boundaries deliberately misaligned with the 5 MiB part size:
      # 64,000 does not divide 5,242,880, so a chunk straddles every boundary.
      # Flushing on "at least a part" would make parts of 5,248,000 — the
      # first size the accumulating buffer reaches — and R2 rejects a
      # multipart upload whose parts are not all equal.
      #
      # The totals are chosen so the two behaviours differ in *part count*
      # too: 164 × 64,000 is exactly two overshooting parts but three exact
      # ones, so the ETag suffix alone tells them apart.
      key = unique_key("exact-parts.bin")
      chunks = for index <- 1..164, do: :binary.copy(<<rem(index, 256)>>, 64_000)
      expected = IO.iodata_to_binary(chunks)

      assert byte_size(expected) == 10_496_000
      assert :ok = S3.put_stream(@bucket, key, chunks)

      assert part_sizes(key) == [5_242_880, 5_242_880, 10_240]
      assert read(key) == expected
    end

    test "a chunk larger than a part is split across parts rather than sent whole" do
      # The carry-forward has to run more than once for a single chunk. Render
      # chunks are far smaller than this, but a part size is a property of the
      # protocol and a chunk size is a property of whoever is feeding us.
      key = unique_key("big-chunk.bin")
      chunks = [:binary.copy("a", 11 * 1024 * 1024), :binary.copy("b", 1024)]

      assert :ok = S3.put_stream(@bucket, key, chunks)

      assert part_sizes(key) == [5_242_880, 5_242_880, 1_049_600]
      assert read(key) == IO.iodata_to_binary(chunks)
    end

    test "a stream of exactly one part size is one part" do
      # The boundary case in both directions: the buffer reaches the part size
      # exactly, so nothing is carried forward and no empty tail part is
      # emitted — S3 rejects a zero-length part.
      key = unique_key("exactly-one-part.bin")
      body = :binary.copy("a", 5 * 1024 * 1024)

      assert :ok = S3.put_stream(@bucket, key, [body])

      assert part_sizes(key) == [5_242_880]
      assert read(key) == body
    end

    test "an object over one part goes multipart" do
      key = unique_key("over-one-part.bin")

      :ok = S3.put_stream(@bucket, key, chunks_totalling(6 * 1024 * 1024))

      assert {:ok, %{etag: etag}} = S3.head(@bucket, key)
      assert etag =~ ~r/-\d+"?$/
    end

    test "the buffered prefix and the resumed tail join without losing bytes" do
      # The seam the suspension creates: everything before it was consumed by
      # the peek, everything after comes from the continuation. An off-by-one
      # there would duplicate or drop a chunk, which byte-equality catches
      # and a size check would not.
      key = unique_key("seam.bin")
      chunks = for index <- 1..120, do: :binary.copy(<<rem(index, 256)>>, 64_000)
      expected = IO.iodata_to_binary(chunks)

      :ok = S3.put_stream(@bucket, key, chunks)

      assert read(key) == expected
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

    test "a range past the end is truncated, not an error", %{key: key} do
      # RFC 9110 §14, and what the local variant store already does. Before
      # this was clamped, the first GET returned short, the offset advanced
      # short of `last`, and the *second* GET drew a 416 — raised from inside
      # a stream whose caller had already started sending a 200.
      assert read(key, {6, 500}) == "6789"
    end

    test "a first at or past the end is invalid", %{key: key} do
      assert S3.get_stream(@bucket, key, {10, 12}) == {:error, :invalid_range}
      assert S3.get_stream(@bucket, key, {10, 10}) == {:error, :invalid_range}
    end

    test "an inverted range is invalid rather than silently empty", %{key: key} do
      assert S3.get_stream(@bucket, key, {5, 2}) == {:error, :invalid_range}
    end

    test "any explicit range on a zero-length object is invalid" do
      key = unique_key("empty-range.bin")
      :ok = S3.put_stream(@bucket, key, [])

      assert S3.get_stream(@bucket, key, {0, 0}) == {:error, :invalid_range}
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

      assert {403, _body} = fetch(tamper(url))
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

  describe "when S3 is unconfigured" do
    setup do
      put_config(%{
        s3: %{AudioProxy.Config.get(:s3) | access_key_id: nil, secret_access_key: nil}
      })

      :ok
    end

    test "every operation refuses rather than letting ex_aws reach for IMDS" do
      # ex_aws reads a nil credential as "not provided" and walks its own
      # provider chain, which ends at an instance-role lookup against
      # 169.254.169.254 — a hang, not a failure, on a host where that address
      # is not routed.
      assert S3.head(@bucket, "k") == {:error, :not_configured}
      assert S3.put_stream(@bucket, "k", ["x"]) == {:error, :not_configured}
      assert S3.get_stream(@bucket, "k") == {:error, :not_configured}
      assert S3.presign_get(@bucket, "k") == {:error, :not_configured}
    end

    test "configured?/0 reports it" do
      refute S3.configured?()
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

  # 200 the first time; every run after, the store reports the bucket as
  # already owned. Anything else is a real failure — wrong credentials, a
  # store that will not accept writes — and is raised here rather than left to
  # surface as a confusing assertion failure three tests later.
  defp ensure_bucket! do
    case @bucket |> ExAws.S3.put_bucket("us-east-1") |> ExAws.request(S3.config()) do
      {:ok, _response} ->
        :ok

      {:error, {:http_error, status, %{body: body}}} when status in [409] ->
        unless body =~ "BucketAlreadyOwnedByYou" or body =~ "BucketAlreadyExists" do
          raise "could not create the #{@bucket} bucket: #{body}"
        end

        :ok

      other ->
        raise "could not create the #{@bucket} bucket: #{inspect(other)}"
    end
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

  # The sizes of a completed object's parts, which no ordinary HEAD reports:
  # a `partNumber` on a HEAD answers for that part alone and carries
  # `x-amz-mp-parts-count`. It is built by hand because `ExAws.S3.head_object`
  # passes only `versionId` through as a query parameter.
  #
  # Reading them back from the store, rather than instrumenting `into_parts/1`,
  # is the point: what has to be uniform is what the store received.
  defp part_sizes(key) do
    {size, count} = part_head(key, 1)

    [
      size
      | Enum.map(2..count//1, fn number -> number |> then(&part_head(key, &1)) |> elem(0) end)
    ]
  end

  defp part_head(key, number) do
    operation = %ExAws.Operation.S3{
      bucket: @bucket,
      path: key,
      http_method: :head,
      params: %{"partNumber" => Integer.to_string(number)}
    }

    assert {:ok, %{headers: headers}} = ExAws.request(operation, S3.config())

    headers = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

    {String.to_integer(headers["content-length"]),
     headers |> Map.get("x-amz-mp-parts-count", "1") |> String.to_integer()}
  end

  # ListMultipartUploads, filtered to one key: the only way to see whether an
  # abort actually happened, since an incomplete upload is invisible to HEAD
  # and to a bucket listing alike.
  defp pending_uploads(key) do
    {:ok, %{body: %{uploads: uploads}}} =
      @bucket |> ExAws.S3.list_multipart_uploads() |> ExAws.request(S3.config())

    uploads |> Enum.map(& &1.key) |> Enum.filter(&(&1 == key))
  end

  # Flips the signature's first hex digit to one it definitely is not. A
  # blanket `s/X-Amz-Signature=./0/` looks equivalent and is a one-in-sixteen
  # flake: when the digit already is `0` the URL comes back untampered and the
  # store rightly answers 200.
  defp tamper(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    <<first::binary-1, rest::binary>> = query["X-Amz-Signature"]

    flipped = if first == "0", do: "1", else: "0"

    URI.to_string(%{
      uri
      | query: URI.encode_query(%{query | "X-Amz-Signature" => flipped <> rest})
    })
  end

  defp chunks_totalling(total) do
    whole = div(total, 64_000)
    remainder = rem(total, 64_000)

    List.duplicate(:binary.copy("a", 64_000), whole) ++
      if remainder > 0, do: [:binary.copy("b", remainder)], else: []
  end

  # Unique per run, so a rerun never reads an object a previous one wrote and
  # the suite needs no teardown.
  defp unique_key(name), do: "#{System.unique_integer([:positive])}/#{name}"
end
