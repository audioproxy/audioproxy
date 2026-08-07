defmodule AudioProxy.RenderCoordinatorPropertyTest do
  @moduledoc """
  The catch-up seam, at join timings nobody chose.

  `AudioProxy.RenderCoordinatorTest` pins the three joins worth naming — before
  any chunk, mid-render, after the render finished. The failure this cannot
  reach that way is a seam that only splits at one particular instant: a chunk
  broadcast in the window between a joiner being handed its backlog and being
  added to the subscriber list would be lost, and a joiner added first and
  handed the backlog second would receive it twice. Both are invisible unless
  the join lands inside that window, so the join time is generated.

  The property is byte equality with the subscriber that started the render.
  `fake_cmd.sh`'s 63-byte period is what makes it sharp: a dropped chunk
  shortens the stream, a duplicated one lengthens it, and a reordering changes
  it without changing its length.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper

  alias AudioProxy.RenderCoordinator
  alias AudioProxy.RenderHarness

  # Eight chunks over roughly 320 ms, so a join anywhere in the generated range
  # lands between two of them rather than always at the same edge.
  @paced List.duplicate(["emit", "63", "sleep", "0.04"], 8) |> List.flatten()
  @paced_bytes RenderHarness.pattern(8 * 63)

  @deadline 5_000

  setup do
    put_config(%{max_src_bytes: 2_000_000_000, max_variant_bytes: 2_000_000_000})
    reset_coordinators()
    reset_probes()
    :ok
  end

  property "a subscriber joining at any moment receives exactly the starter's bytes" do
    # Past the render's own ~320 ms as well as inside it: a join after it has
    # finished still coalesces, out of the linger, and must produce the same
    # bytes from the backlog alone.
    check all(delay <- integer(0..450), max_runs: 15) do
      key = "seam-#{System.unique_integer([:positive, :monotonic])}"

      starter = Task.async(fn -> subscribe_and_collect(key) end)
      Process.sleep(delay)
      joiner = Task.async(fn -> subscribe_and_collect(key) end)

      assert Task.await(starter, @deadline) == @paced_bytes
      assert Task.await(joiner, @deadline) == @paced_bytes
    end
  end

  defp subscribe_and_collect(key) do
    spec = [args: @paced, executable: RenderHarness.fake_cmd()]
    {:ok, _status, render, backlog} = RenderCoordinator.subscribe(key, spec)

    collect(render, Enum.reverse(backlog))
  end

  defp collect(render, chunks) do
    receive do
      {:chunk, ^render, data} -> collect(render, [data | chunks])
      {:done, ^render, _info} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, ^render, failure} -> flunk("render failed: #{inspect(failure)}")
    after
      @deadline -> flunk("render produced no terminal message")
    end
  end
end
