defmodule AudioProxy.VariantStore.LocalTest do
  @moduledoc """
  The `file://` backend against a per-test tmp root: round trips, layout,
  Range slices, and — most load-bearing — atomic-or-absent writes.

  Everything goes through `AudioProxy.VariantStore`'s facade, so the dispatch
  from the configured store to this backend is exercised by every test rather
  than trusted.

  `async: false`, because the store root lives in the global config.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.VariantStore

  @moduletag tmp_dir: "variant_store_local"

  @metadata %{
    content_type: "audio/ogg",
    cache_control: "public, max-age=31536000, immutable",
    etag: ~s("0123abcd")
  }

  setup %{tmp_dir: tmp_dir} do
    put_config(%{variant_store: {:file, tmp_dir}})
    {:ok, root: tmp_dir}
  end

  # A well-formed cache key nothing else in the suite has used.
  defp key do
    :sha256
    |> :crypto.hash("#{System.unique_integer([:positive, :monotonic])}")
    |> Base.encode16(case: :lower)
  end

  defp put!(key, bytes, metadata \\ @metadata) do
    assert :ok = VariantStore.put_stream(key, chunked(bytes), metadata)
  end

  # Written as several chunks on purpose, so a put is never one write.
  defp chunked(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.chunk_every(7) |> Enum.map(&:binary.list_to_bin/1)

  defp read!(key, range \\ nil) do
    assert {:ok, stream} = VariantStore.get_stream(key, range)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  describe "round trip" do
    test "bytes and metadata survive put → head → get, byte-identical" do
      key = key()
      put!(key, "some rendered audio bytes")

      assert {:ok, %{size: 25, metadata: @metadata}} = VariantStore.head(key)
      assert read!(key) == "some rendered audio bytes"
    end

    test "the content type is the stored one, not a store default (store-direct fetch)" do
      key = key()
      put!(key, "OggS…", %{@metadata | content_type: "audio/ogg"})

      assert {:ok, %{metadata: %{content_type: "audio/ogg"}}} = VariantStore.head(key)
    end

    test "a zero-length variant is stored and served as such" do
      key = key()
      put!(key, "")

      assert {:ok, %{size: 0}} = VariantStore.head(key)
      assert read!(key) == ""
    end

    test "a second put for the same key replaces the first, whole" do
      key = key()
      put!(key, "first")
      put!(key, "second render", %{@metadata | etag: ~s("other")})

      assert {:ok, %{size: 13, metadata: %{etag: ~s("other")}}} = VariantStore.head(key)
      assert read!(key) == "second render"
    end
  end

  describe "layout" do
    test "keys fan out by prefix instead of piling into one directory", %{root: root} do
      key = key()
      put!(key, "bytes")

      fanned_out = Path.join([root, binary_part(key, 0, 2), binary_part(key, 2, 2), key])

      assert File.regular?(fanned_out)
      assert File.regular?(fanned_out <> ".meta")
    end

    test "a key that is not a cache key is refused, not turned into a path", %{root: root} do
      probe = Path.join(root, "escape")

      assert {:error, :invalid_key} = VariantStore.put_stream("../../escape", ["x"], @metadata)
      assert {:error, :not_found} = VariantStore.head("../../escape")

      refute File.exists?(probe)
    end
  end

  describe "misses" do
    test "a key never written is not found" do
      assert {:error, :not_found} = VariantStore.head(key())
      assert {:error, :not_found} = VariantStore.get_stream(key(), nil)
    end

    test "bytes without their sidecar are not readable", %{root: root} do
      key = key()
      put!(key, "bytes")
      File.rm!(Path.join([root, binary_part(key, 0, 2), binary_part(key, 2, 2), key <> ".meta"]))

      assert {:error, :not_found} = VariantStore.head(key)
    end
  end

  describe "ranges" do
    setup do
      key = key()
      put!(key, "0123456789")
      {:ok, key: key}
    end

    test "an interior slice is exactly those bytes", %{key: key} do
      assert read!(key, {2, 5}) == "2345"
    end

    test "a last past the end is truncated, per Range semantics", %{key: key} do
      assert read!(key, {6, 500}) == "6789"
    end

    test "a first past the end is invalid", %{key: key} do
      assert {:error, :invalid_range} = VariantStore.get_stream(key, {10, 12})
    end

    test "an inverted range is invalid", %{key: key} do
      assert {:error, :invalid_range} = VariantStore.get_stream(key, {5, 2})
    end
  end

  describe "streamed reads" do
    test "a large variant comes back in bounded chunks, byte-identical" do
      key = key()
      bytes = :crypto.strong_rand_bytes(200_000)
      assert :ok = VariantStore.put_stream(key, [bytes], @metadata)

      {:ok, stream} = VariantStore.get_stream(key, nil)
      chunks = Enum.to_list(stream)

      # More than one chunk is the property: the variant was not read whole.
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1) <= 65_536))
      assert IO.iodata_to_binary(chunks) == bytes
    end
  end

  describe "atomic or absent" do
    test "a chunk stream that raises leaves nothing readable and nothing staged", %{root: root} do
      key = key()

      aborting =
        Stream.map(1..10, fn
          5 -> raise "render died mid-stream"
          n -> "chunk-#{n}"
        end)

      assert {:error, %RuntimeError{}} = VariantStore.put_stream(key, aborting, @metadata)

      assert {:error, :not_found} = VariantStore.head(key)
      assert File.ls!(Path.join(root, "tmp")) == []
    end

    test "a write failure reports and leaves nothing readable", %{root: root} do
      key = key()

      # The root refuses writes, so staging fails at the first touch.
      File.chmod!(root, 0o555)
      on_exit(fn -> File.chmod!(root, 0o755) end)

      assert {:error, :eacces} = VariantStore.put_stream(key, ["bytes"], @metadata)
      File.chmod!(root, 0o755)
      assert {:error, :not_found} = VariantStore.head(key)
    end
  end
end
