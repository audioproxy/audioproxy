defmodule AudioProxy.ProbeEndpointTest do
  @moduledoc """
  Probe coalescing where it bites: signed requests, and the `ffprobe` processes
  they do or do not start.

  `AudioProxy.ProbeCoordinatorTest` proves the mechanism. This proves the
  wiring — that a burst of requests for one source costs one probe rather than
  one each, that `/info` and the render endpoint's audio-only gate share that
  probe, and that a request which never reaches the gate never spawns one.

  Driven through `AudioProxy.CountingProbe.Router`, which is the production
  chain with a prober that keeps a tally beside the source.

  `async: false`: the config and both registries are one global thing.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.ProbeCoalesceHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.{
    CacheKey,
    FakeFfmpeg,
    RenderCoordinator,
    Semaphore,
    Signature,
    VariantStore
  }

  @moduletag tmp_dir: "probe_endpoint"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @opts AudioProxy.CountingProbe.Router.init([])

  @deadline 10_000

  setup %{tmp_dir: tmp_dir} do
    # `hang.wav` is `fake_ffmpeg.sh`'s directive for a render that never
    # produces a byte, which is how a render slot is held for a whole test.
    for name <- ~w(piece.wav probeslow.wav other.wav video.mp4 cached.wav hang.wav) do
      File.write!(Path.join(tmp_dir, name), "RIFF-fake-wav-bytes")
    end

    # No variant store by default, and only the HIT test configures one. A
    # write-back tee outlives the response it was started for by however long
    # the store takes, so a test that ends while one is running hands it to
    # whatever configuration the next test installs — which is a warning about
    # nothing, in a suite where an unexplained warning is the expensive kind.
    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000,
      max_variant_bytes: 2_000_000_000,
      variant_store: nil
    })

    reset_coordinators()
    reset_probes()

    {:ok, dir: tmp_dir}
  end

  describe "one probe per source, across the endpoints that need one" do
    test "a burst of render requests for one source probes once", %{dir: dir} do
      responses = burst(10, fn -> get("/f:mp3/plain/local://probeslow.wav") end)

      assert Enum.all?(responses, &(&1.status == 200))
      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "requests for different variants of one source still probe once", %{dir: dir} do
      # The identity is the source, not the cache key — so these coalesce here
      # even though they will not coalesce at the render coordinator, which is
      # the one place this module's key deliberately differs from that one's.
      responses =
        burst(
          8,
          fn ->
            options = Enum.random(~w(f:mp3 f:opus/br:96 f:flac f:wav))
            get("/#{options}/plain/local://probeslow.wav")
          end
        )

      assert Enum.all?(responses, &(&1.status == 200))
      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "/info and the render gate share the probe", %{dir: dir} do
      # Both endpoints ask ffprobe the same question about the same bytes, and
      # after this change they ask it once. Interleaved deliberately: whichever
      # arrives first is the one that spawns.
      responses =
        burst(8, fn ->
          if rem(System.unique_integer([:positive]), 2) == 0 do
            get("/info/plain/local://probeslow.wav")
          else
            get("/f:mp3/plain/local://probeslow.wav")
          end
        end)

      assert Enum.all?(responses, &(&1.status == 200))
      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "a refused source refuses every waiter, from one probe", %{dir: dir} do
      responses = burst(8, fn -> get("/f:mp3/plain/local://video.mp4") end)

      assert Enum.all?(responses, &(&1.status == 415))
      assert FakeFfmpeg.probe_count(dir) == 1

      # The case the proposal calls the interesting one: refused sources never
      # reach the semaphore, so nothing downstream would ever have shed them.
      assert %{held: 0} = Semaphore.stats()
    end
  end

  describe "a request that never probes" do
    test "a cache HIT probes not at all", %{dir: dir} do
      store = Path.join(dir, "store")
      File.mkdir_p!(store)
      put_config(%{variant_store: {:file, store}, serve_mode: :proxy})

      options = "f:opus/br:96"
      rest = "/#{options}/plain/local://cached.wav"
      key = CacheKey.derive!(options, "local://cached.wav")

      :ok =
        VariantStore.put_stream(key, ["stored-variant-bytes"], %{
          content_type: "audio/ogg",
          cache_control: "public, max-age=31536000, immutable, no-transform",
          etag: ~s("#{key}")
        })

      conn = get(rest)

      assert conn.status == 200
      assert conn.resp_body == "stored-variant-bytes"
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]

      # The point, stated as the count: the bytes already exist, so the gate
      # never runs and no probe is spawned for this request at all.
      assert FakeFfmpeg.probe_count(dir) == 0

      # The store is this test's alone, so wait for the write-back to settle
      # rather than hand a running tee to whatever configuration comes next.
      wait_until(fn -> DynamicSupervisor.which_children(RenderCoordinator.Supervisor) == [] end)
    end

    test "a 304 revalidation does not either", %{dir: dir} do
      options = "f:mp3"
      rest = "/#{options}/plain/local://piece.wav"
      etag = ~s("#{CacheKey.derive!(options, "local://piece.wav")}")

      conn =
        conn(:get, signed(rest))
        |> put_req_header("if-none-match", etag)
        |> AudioProxy.CountingProbe.Router.call(@opts)

      assert conn.status == 304
      assert FakeFfmpeg.probe_count(dir) == 0
    end
  end

  ## Helpers

  defp get(rest) do
    rest |> signed() |> then(&conn(:get, &1)) |> AudioProxy.CountingProbe.Router.call(@opts)
  end

  defp signed(rest), do: "/#{Signature.sign(rest, @key, @salt)}#{rest}"

  defp burst(count, request) do
    1..count
    |> Task.async_stream(fn _ -> request.() end, max_concurrency: count, timeout: @deadline)
    |> Enum.map(fn {:ok, conn} -> conn end)
  end

  defp wait_until(condition, remaining \\ @deadline)

  defp wait_until(_condition, remaining) when remaining <= 0, do: flunk("condition never held")

  defp wait_until(condition, remaining) do
    unless condition.() do
      Process.sleep(10)
      wait_until(condition, remaining - 10)
    end
  end
end
