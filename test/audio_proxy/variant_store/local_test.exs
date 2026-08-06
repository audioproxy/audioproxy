defmodule AudioProxy.VariantStore.LocalTest do
  @moduledoc """
  The `file://` backend's own mechanisms: the fan-out, the `.meta` sidecar,
  the `tmp/` staging, and the rename that makes a write atomic.

  The *contract* is not here. Round trips, Range slices, misses and aborted
  writes are `AudioProxy.VariantStoreParity`'s, run against this backend by
  `AudioProxy.VariantStore.ParityLocalTest` and against `s3://` by
  `AudioProxy.VariantStore.ParityS3Test`. What stays in this file is what a
  client cannot observe and this backend still has to get right — the how,
  not the what.

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
    test "bytes without their sidecar are not readable", %{root: root} do
      key = key()
      put!(key, "bytes")
      File.rm!(Path.join([root, binary_part(key, 0, 2), binary_part(key, 2, 2), key <> ".meta"]))

      assert {:error, :not_found} = VariantStore.head(key)
    end
  end

  describe "streamed reads" do
    test "reads are bounded by this backend's own chunk size" do
      # That there is more than one chunk is parity's; that a chunk is at most
      # 64 KiB is this backend's read granularity and nothing else's.
      key = key()
      bytes = :crypto.strong_rand_bytes(200_000)
      assert :ok = VariantStore.put_stream(key, [bytes], @metadata)

      {:ok, stream} = VariantStore.get_stream(key, nil)
      chunks = Enum.to_list(stream)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1) <= 65_536))
      assert IO.iodata_to_binary(chunks) == bytes
    end
  end

  describe "atomic or absent" do
    test "a chunk stream that raises leaves nothing staged", %{root: root} do
      # That it leaves nothing *readable* is parity's. What is this backend's
      # alone is that the staging directory is empty afterwards — an S3 upload
      # has no `tmp/` to leak into.
      key = key()

      aborting =
        Stream.map(1..10, fn
          5 -> raise "render died mid-stream"
          n -> "chunk-#{n}"
        end)

      assert {:error, %RuntimeError{}} = VariantStore.put_stream(key, aborting, @metadata)

      assert File.ls!(Path.join(root, "tmp")) == []
    end

    test "a failing put leaves a foreign sidecar alone", %{root: root} do
      # The window this pins: another put for the same key has renamed its
      # sidecar into place and not yet its data file. A failing put tidying
      # "the" orphan meta there would erase that put's committed metadata.
      key = key()
      meta = Path.join([root, binary_part(key, 0, 2), binary_part(key, 2, 2), key <> ".meta"])
      File.mkdir_p!(Path.dirname(meta))
      File.write!(meta, "someone else's commit in progress")

      aborting = Stream.map(1..3, fn _ -> raise "render died" end)
      assert {:error, _reason} = VariantStore.put_stream(key, aborting, @metadata)

      assert File.read!(meta) == "someone else's commit in progress"
    end

    test "sweep_staging clears leftovers from killed writes, and only those", %{root: root} do
      key = key()
      put!(key, "a committed variant")

      stale = Path.join([root, "tmp", "#{key}.99.data"])
      File.write!(stale, "half-written staging from a crash")

      assert :ok = AudioProxy.VariantStore.Local.sweep_staging(root)

      refute File.exists?(stale)
      assert {:ok, %{size: 19}} = VariantStore.head(key)
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
