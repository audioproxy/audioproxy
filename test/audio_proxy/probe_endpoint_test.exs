defmodule AudioProxy.ProbeEndpointTest do
  @moduledoc """
  The probe pool where it bites: signed requests, and the `ffprobe` processes
  they do or do not start.

  `AudioProxy.ProbeCoordinatorTest` proves the coalescing and
  `AudioProxy.ProbeLimiterTest` proves the counting. This proves the wiring —
  that a burst of requests for one source costs one probe rather than one each,
  that `/info` and the render endpoint's audio-only gate share that probe, that
  a full probe pool reaches the client as §5's 429 with a `Retry-After`, and
  that neither pool is consulted for a request that never probes.

  Driven through `AudioProxy.CountingProbe.Router`, which is the production
  chain with a prober that keeps a tally beside the source.

  `async: false`: the config, both registries and both pools are one global
  thing.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest, except: [conn: 3]
  import AudioProxy.ProbeCoalesceHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.{
    CacheKey,
    FakeFfmpeg,
    ProbeLimiter,
    RenderCoordinator,
    Semaphore,
    VariantStore
  }

  @moduletag tmp_dir: "probe_endpoint"

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
    put_config(base_config(local_root: tmp_dir, max_probe_concurrency: 8, variant_store: nil))

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

  describe "the probe ceiling, from the client's side" do
    test "an exhausted pool is 429 with a Retry-After", %{dir: dir} do
      put_config(%{max_probe_concurrency: 1})

      # One slow probe holds the only slot; a request for a *different* source
      # arrives while it does, so there is nothing to coalesce onto.
      held = Task.async(fn -> get("/f:mp3/plain/local://probeslow.wav") end)
      wait_until(fn -> FakeFfmpeg.probe_count(dir) == 1 end)

      conn = get("/f:mp3/plain/local://piece.wav")

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
      assert JSON.decode!(conn.resp_body)["error"] == "queue_full"

      assert Task.await(held, @deadline).status == 200

      # Refused rather than queued: the second source was never probed.
      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "a probe does not wait behind a render slot", %{dir: dir} do
      # Every render slot held and no room to wait. A request that needs a
      # render is shed; one that only needs a probe is not, which is the whole
      # reason the probe path has a counter of its own.
      put_config(%{max_concurrency: 1, queue_size: 0})

      hanging = Task.async(fn -> get("/f:mp3/plain/local://hang.wav") end)
      wait_until(fn -> Semaphore.stats().held == 1 end)

      # Captured *before*, because the hanging render's own gate probe has
      # already made the count 1: asserting `>= 1` afterwards would hold for a
      # proxy in which the second probe never ran at all.
      before = FakeFfmpeg.probe_count(dir)

      assert get("/info/plain/local://piece.wav").status == 200
      assert FakeFfmpeg.probe_count(dir) == before + 1

      assert %{held: 0} = ProbeLimiter.stats()

      Task.shutdown(hanging, :brutal_kill)
    end
  end

  describe "a request that never probes" do
    test "a cache HIT needs neither pool", %{dir: dir} do
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

      # Both pools exhausted-by-configuration: one probe slot, held, and no
      # render slot at all to be had.
      put_config(%{max_probe_concurrency: 1, max_concurrency: 1, queue_size: 0})

      held = Task.async(fn -> get("/f:mp3/plain/local://probeslow.wav") end)
      wait_until(fn -> FakeFfmpeg.probe_count(dir) == 1 end)

      conn = get(rest)

      assert conn.status == 200
      assert conn.resp_body == "stored-variant-bytes"
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]

      # The point, stated as the count: the HIT is served from bytes that
      # already exist, so it asks neither pool for anything.
      assert FakeFfmpeg.probe_count(dir) == 1

      assert Task.await(held, @deadline).status == 200

      # And then wait for the render that held the probe slot to finish being
      # written back, since this is the one test with somewhere to write.
      wait_until(fn -> DynamicSupervisor.which_children(RenderCoordinator.Supervisor) == [] end)
    end

    test "a 304 revalidation needs neither either", %{dir: dir} do
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
