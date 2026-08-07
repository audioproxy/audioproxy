defmodule AudioProxy.ProbeCoordinatorTest do
  @moduledoc """
  Single-flight, verdict lifetime and teardown for the probe path, driven
  against `counting_ffprobe.sh`.

  Everything here is a property of the coordinator rather than of ffprobe: how
  many subprocesses a burst starts, what a request arriving after the verdict
  is handed, and what a failure leaves behind. The tally the stand-in keeps is
  what makes the first of those assertable as a number — see
  `AudioProxy.FakeFfmpeg.counting_probe_path/0`.

  `async: false`, because the registry and the config are global.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.ProbeCoalesceHelper

  alias AudioProxy.{FakeFfmpeg, ProbeCoordinator}

  @moduletag tmp_dir: "probe_coordinator"

  @deadline 10_000

  setup %{tmp_dir: tmp_dir} do
    for name <- ~w(piece.wav probeslow.wav other.wav unprobeable.txt probehang.wav video.mp4) do
      File.write!(Path.join(tmp_dir, name), "fake-bytes")
    end

    put_config(%{
      local_root: tmp_dir,
      max_probe_concurrency: 8,
      # Short, so the timeout test is not the slowest thing in the suite.
      probe_timeout: 1
    })

    reset_probes()

    {:ok, dir: tmp_dir}
  end

  describe "single flight" do
    test "a concurrent burst on one source spawns exactly one probe", %{dir: dir} do
      # `probeslow` is what makes this about probes *in flight*: the burst is
      # still arriving when the first one is half a second from answering, so
      # every other caller joins a running probe rather than reading a verdict
      # that was already held.
      results =
        1..20
        |> Task.async_stream(fn _ -> probe(dir, "probeslow.wav") end,
          max_concurrency: 20,
          timeout: @deadline
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == 20
      assert Enum.all?(results, &match?({:ok, %{"streams" => [_ | _]}}, &1))

      # The property, stated as the number the whole change exists to change.
      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "distinct sources probe independently", %{dir: dir} do
      one = Task.async(fn -> probe(dir, "piece.wav") end)
      other = Task.async(fn -> probe(dir, "other.wav") end)

      assert {:ok, _} = Task.await(one, @deadline)
      assert {:ok, _} = Task.await(other, @deadline)

      assert FakeFfmpeg.probe_count(dir) == 2
    end

    test "a shared probe shares its verdict, refusal and all", %{dir: dir} do
      # The audio-only gate's case: one probe, and every waiter learns the same
      # thing about the same bytes. Mapping that to a 415 is the caller's job —
      # `AudioProxy.RenderEndpointTest` asserts that half.
      results =
        1..8
        |> Task.async_stream(fn _ -> probe(dir, "video.mp4") end, timeout: @deadline)
        |> Enum.map(fn {:ok, {:ok, verdict}} -> AudioProxy.Ffprobe.has_video?(verdict) end)

      assert results == List.duplicate(true, 8)
      assert FakeFfmpeg.probe_count(dir) == 1
    end
  end

  describe "a verdict, once it is in" do
    test "answers a later request without a second spawn", %{dir: dir} do
      assert {:ok, _} = probe(dir, "piece.wav")
      assert {:ok, _} = probe(dir, "piece.wav")

      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "is not held forever — after the linger, the next request probes", %{dir: dir} do
      assert {:ok, _} = probe(dir, "piece.wav")

      # Past the coordinator's linger. This is in-flight sharing, deliberately
      # not the cross-request cache the proposal left out of scope, and a test
      # that did not pin the difference would let one quietly become the other.
      Process.sleep(1_500)

      assert {:ok, _} = probe(dir, "piece.wav")
      assert FakeFfmpeg.probe_count(dir) == 2
    end
  end

  describe "failure" do
    test "fails every waiter with the reason the probe reported", %{dir: dir} do
      results =
        1..8
        |> Task.async_stream(fn _ -> probe(dir, "unprobeable.txt") end, timeout: @deadline)
        |> Enum.map(fn {:ok, result} -> result end)

      assert results == List.duplicate({:error, :undecodable_source}, 8)
    end

    test "leaves no entry behind, so the next request probes again", %{dir: dir} do
      assert {:error, :undecodable_source} = probe(dir, "unprobeable.txt")
      refute registered?("unprobeable.txt")

      assert {:error, :undecodable_source} = probe(dir, "unprobeable.txt")

      # Two spawns for two requests: a failed probe is not a cached "no".
      assert FakeFfmpeg.probe_count(dir) == 2
    end

    test "a probe that outruns AP_PROBE_TIMEOUT fails its waiters alike", %{dir: dir} do
      results =
        1..4
        |> Task.async_stream(fn _ -> probe(dir, "probehang.wav") end, timeout: @deadline)
        |> Enum.map(fn {:ok, result} -> result end)

      assert results == List.duplicate({:error, :probe_timeout}, 4)
      refute registered?("probehang.wav")
      assert FakeFfmpeg.probe_count(dir) == 1
    end
  end

  describe "the probe ceiling" do
    test "refuses with the 429 the render queue produces, not a status of its own", %{dir: dir} do
      put_config(%{max_probe_concurrency: 1})

      # One slow probe holds the only slot for half a second; a second, distinct
      # source arrives while it does.
      held = Task.async(fn -> probe(dir, "probeslow.wav") end)
      wait_until(fn -> FakeFfmpeg.probe_count(dir) == 1 end)

      assert {:error, {:queue_full, retry_after}} = probe(dir, "piece.wav")
      assert retry_after >= 1

      assert {:ok, _} = Task.await(held, @deadline)

      # Refused, not queued: the second source was never probed at all.
      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "counts probes rather than requests, so joiners are free", %{dir: dir} do
      # A ceiling of one, and twenty requests for one source. Every one is
      # answered: nineteen of them coalesce onto the slot the first took, which
      # is what makes the two halves of this change compose.
      put_config(%{max_probe_concurrency: 1})

      results =
        1..20
        |> Task.async_stream(fn _ -> probe(dir, "probeslow.wav") end,
          max_concurrency: 20,
          timeout: @deadline
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert FakeFfmpeg.probe_count(dir) == 1
    end

    test "is given back as soon as the verdict is, not when the linger ends", %{dir: dir} do
      # The slot is released before the coordinator starts holding its verdict.
      # A ceiling of one plus a linger that held the slot would make a second,
      # distinct source wait a linger for a probe that had already finished.
      put_config(%{max_probe_concurrency: 1})

      assert {:ok, _} = probe(dir, "piece.wav")
      assert {:ok, _} = probe(dir, "other.wav")

      assert FakeFfmpeg.probe_count(dir) == 2
    end
  end

  ## Helpers

  # The identity is the canonical source, which is what the two endpoints agree
  # on; the input is the absolute path ffprobe is handed.
  defp probe(dir, name) do
    ProbeCoordinator.probe(
      "local://#{name}",
      Path.join(dir, name),
      protocols: "file",
      executable: FakeFfmpeg.counting_probe_path()
    )
  end

  # The registry rather than the supervisor's child list, and the difference is
  # the point of the assertion: what "no entry left behind" means is that the
  # next request cannot *attach* to this identity. A coordinator that has
  # unregistered and is still terminating is invisible to a joiner and visible
  # to `DynamicSupervisor.which_children/1`, so counting children would be a
  # race dressed up as a property.
  defp registered?(name) do
    Registry.lookup(ProbeCoordinator.Registry, "local://#{name}") != []
  end

  defp wait_until(condition, remaining \\ 5_000)

  defp wait_until(_condition, remaining) when remaining <= 0 do
    flunk("condition never held")
  end

  defp wait_until(condition, remaining) do
    unless condition.() do
      Process.sleep(25)
      wait_until(condition, remaining - 25)
    end
  end
end
