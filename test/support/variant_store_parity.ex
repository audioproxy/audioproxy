defmodule AudioProxy.VariantStoreParity do
  @moduledoc """
  The seam's whole surface, asserted once and run against every backend.

  `AudioProxy.VariantStore` is a behaviour with two implementations, and until
  this existed the only thing holding them to the same contract was that both
  authors had read the same moduledoc. That is not a guarantee — a backend
  whose Range clamping, whose miss vocabulary, or whose metadata round trip
  differed by a byte would surprise a deployment rather than fail a test.

  So the assertions live here and the backends are the parameter:

      defmodule AudioProxy.VariantStore.ParityLocalTest do
        use ExUnit.Case, async: false
        use AudioProxy.VariantStoreParity
        setup do: put_config(%{variant_store: {:file, ...}})
      end

  Every call goes through the `AudioProxy.VariantStore` facade rather than the
  backend module, so dispatch is exercised too.

  ## What is deliberately not here

  Mechanisms. The local backend's `tmp/` staging and its `.meta` sidecar, the
  S3 backend's flat key layout — those are how each one keeps the contract,
  not the contract, and they stay in their own suites. The rule of thumb: if
  removing the assertion could not change what a *client* observes, it is not
  parity.

  The failed-write case is the one that looks like an exception and is not.
  What the shared suite pins is that a write which aborts reports the error as
  data and leaves nothing readable — which is precisely what
  `AudioProxy.VariantStore.Tee` turns into "the client keeps its bytes and the
  failure becomes telemetry". The tee's own behaviour is then backend-independent
  by construction, which is why it is tested once rather than twice.
  """

  defmacro __using__(_opts) do
    quote do
      alias AudioProxy.VariantStore

      @parity_metadata %{
        content_type: "audio/ogg",
        cache_control: "public, max-age=31536000, immutable",
        etag: ~s("0123abcd")
      }

      # A well-formed cache key nothing else in the suite has used. Uniqueness
      # matters more here than in a `tmp_dir`-scoped suite: an object store is
      # shared between runs, so a fixed key would pick up the last run's bytes.
      defp parity_key do
        :sha256
        |> :crypto.hash("#{System.unique_integer([:positive, :monotonic])}#{System.os_time()}")
        |> Base.encode16(case: :lower)
      end

      # Written as several chunks on purpose, so a put is never one write.
      defp parity_put!(key, bytes, metadata \\ @parity_metadata) do
        chunks =
          bytes
          |> :binary.bin_to_list()
          |> Enum.chunk_every(7)
          |> Enum.map(&:binary.list_to_bin/1)

        assert :ok = VariantStore.put_stream(key, chunks, metadata)
      end

      defp parity_read!(key, range \\ nil) do
        assert {:ok, stream} = VariantStore.get_stream(key, range)
        stream |> Enum.to_list() |> IO.iodata_to_binary()
      end

      describe "parity: round trip" do
        test "bytes and metadata survive put → head → get, byte-identical" do
          key = parity_key()
          parity_put!(key, "some rendered audio bytes")

          assert {:ok, %{size: 25, metadata: metadata}} = VariantStore.head(key)
          assert metadata == @parity_metadata
          assert parity_read!(key) == "some rendered audio bytes"
        end

        test "the content type is the stored one, not a store default" do
          # The redirect case in miniature: a store that answered
          # `application/octet-stream` here would hand a player something it
          # may refuse to decode, with no proxy in the path to correct it.
          key = parity_key()
          parity_put!(key, "ID3…", %{@parity_metadata | content_type: "audio/mpeg"})

          assert {:ok, %{metadata: %{content_type: "audio/mpeg"}}} = VariantStore.head(key)
        end

        test "a zero-length variant is stored and served as such" do
          key = parity_key()
          parity_put!(key, "")

          assert {:ok, %{size: 0}} = VariantStore.head(key)
          assert parity_read!(key) == ""
        end

        test "a second put for the same key replaces the first, whole" do
          key = parity_key()
          parity_put!(key, "first")
          parity_put!(key, "second render", %{@parity_metadata | etag: ~s("other")})

          assert {:ok, %{size: 13, metadata: %{etag: ~s("other")}}} = VariantStore.head(key)
          assert parity_read!(key) == "second render"
        end
      end

      describe "parity: misses" do
        test "a key never written is not found, by head and by read alike" do
          key = parity_key()

          assert {:error, :not_found} = VariantStore.head(key)
          assert {:error, :not_found} = VariantStore.get_stream(key, nil)
        end

        test "a key that is not a cache key is refused rather than looked up" do
          assert {:error, :not_found} = VariantStore.head("../../escape")

          assert {:error, :invalid_key} =
                   VariantStore.put_stream("../../escape", ["x"], @parity_metadata)
        end
      end

      describe "parity: ranges" do
        setup do
          key = parity_key()
          parity_put!(key, "0123456789")
          {:ok, parity_range_key: key}
        end

        test "an interior slice is exactly those bytes", %{parity_range_key: key} do
          assert parity_read!(key, {2, 5}) == "2345"
        end

        test "a single byte is reachable, including the last", %{parity_range_key: key} do
          assert parity_read!(key, {4, 4}) == "4"
          assert parity_read!(key, {9, 9}) == "9"
        end

        test "a last past the end is truncated, per RFC 9110 §14", %{parity_range_key: key} do
          assert parity_read!(key, {6, 500}) == "6789"
        end

        test "a first at or past the end is invalid", %{parity_range_key: key} do
          assert {:error, :invalid_range} = VariantStore.get_stream(key, {10, 12})
          assert {:error, :invalid_range} = VariantStore.get_stream(key, {10, 10})
        end

        test "an inverted range is invalid rather than silently empty",
             %{parity_range_key: key} do
          assert {:error, :invalid_range} = VariantStore.get_stream(key, {5, 2})
        end
      end

      describe "parity: streamed reads" do
        test "a large variant comes back in bounded chunks, byte-identical" do
          # Larger than either backend's read granularity, so the chunking is
          # genuinely exercised rather than collapsing into one read. The chunk
          # *size* differs between backends and is not parity; that there is
          # more than one of them is.
          key = parity_key()
          bytes = :crypto.strong_rand_bytes(2_500_000)
          assert :ok = VariantStore.put_stream(key, [bytes], @parity_metadata)

          {:ok, stream} = VariantStore.get_stream(key, nil)
          chunks = Enum.to_list(stream)

          assert length(chunks) > 1
          assert IO.iodata_to_binary(chunks) == bytes
        end
      end

      describe "parity: a failed write leaves nothing readable" do
        test "a chunk stream that raises comes back as data, not as an exception" do
          key = parity_key()

          aborting =
            Stream.map(1..10, fn
              5 -> raise "render died mid-stream"
              n -> "chunk-#{n}"
            end)

          assert {:error, %RuntimeError{}} =
                   VariantStore.put_stream(key, aborting, @parity_metadata)

          assert {:error, :not_found} = VariantStore.head(key)
        end

        test "a write that aborts past one part still leaves nothing readable" do
          # Past the point where a backend has committed *something* somewhere:
          # for S3 that is an initiated multipart upload with parts already
          # sent, for the local store a staged temp file with real bytes in it.
          # Either way the key must still read as absent.
          key = parity_key()

          aborting =
            Stream.map(1..20, fn
              18 -> raise "render died after several parts"
              _ -> :binary.copy("x", 512_000)
            end)

          assert {:error, %RuntimeError{}} =
                   VariantStore.put_stream(key, aborting, @parity_metadata)

          assert {:error, :not_found} = VariantStore.head(key)
        end
      end
    end
  end
end
