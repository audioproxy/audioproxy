defmodule AudioProxy.VariantStore.TeeTest do
  @moduledoc """
  The write-back, driven through `AudioProxy.RenderCoordinator` against
  `fake_cmd.sh` and a per-test `file://` store: byte equality, metadata,
  atomic-or-absent, the disconnect policy both ways, and a write failure
  clients never see.

  Everything subscribes the way the render action does — a spec carrying
  `:metadata` — because the tee's whole contract is being one more
  subscriber to the same broadcast.

  `async: false`: registry, config and telemetry handlers are all global.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper

  alias AudioProxy.{RenderCoordinator, RenderHarness, VariantStore}

  @moduletag tmp_dir: "variant_store_tee"

  # Three chunks with gaps — the same pacing the coordinator tests use, so
  # "mid-render" is a real place to stand.
  @paced ["emit", "63", "sleep", "0.2", "emit", "63", "sleep", "0.2", "emit", "63"]
  @paced_bytes RenderHarness.pattern(189)

  @metadata %{
    content_type: "audio/ogg",
    cache_control: "public, max-age=31536000, immutable",
    etag: ~s("deadbeef")
  }

  @deadline 5_000

  setup %{tmp_dir: tmp_dir} do
    put_config(%{
      max_src_bytes: 2_000_000_000,
      max_variant_bytes: 2_000_000_000,
      variant_store: {:file, tmp_dir}
    })

    reset_coordinators()
    reset_probes()
    {:ok, root: tmp_dir}
  end

  defp key do
    :sha256
    |> :crypto.hash("tee-#{System.unique_integer([:positive, :monotonic])}")
    |> Base.encode16(case: :lower)
  end

  defp spec(directives) do
    [args: directives, executable: RenderHarness.fake_cmd(), metadata: @metadata]
  end

  defp stored!(key) do
    {:ok, stream} = VariantStore.get_stream(key, nil)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp wait_until(condition, remaining \\ @deadline)
  defp wait_until(_condition, remaining) when remaining <= 0, do: flunk("condition never held")

  defp wait_until(condition, remaining) do
    unless condition.() do
      Process.sleep(10)
      wait_until(condition, remaining - 10)
    end
  end

  defp collect(render, chunks \\ []) do
    receive do
      {:chunk, ^render, data} -> collect(render, [data | chunks])
      {:done, ^render, _info} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, ^render, failure} -> {:error, failure}
    after
      @deadline -> flunk("render never finished")
    end
  end

  describe "write-back on success" do
    test "the stored bytes are the response bytes, with the metadata (store-direct fetch)" do
      key = key()
      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(@paced))

      assert {:ok, received} = collect(render)
      assert received == @paced_bytes

      wait_until(fn -> match?({:ok, _entry}, VariantStore.head(key)) end)

      assert {:ok, %{size: 189, metadata: @metadata}} = VariantStore.head(key)
      assert stored!(key) == received
    end

    test "a slow client does not delay the store: the variant is complete first" do
      key = key()
      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(@paced))

      # This client reads nothing at all until the variant is committed —
      # the store filling first is exactly the full-speed-render policy.
      wait_until(fn -> match?({:ok, _entry}, VariantStore.head(key)) end)
      assert stored!(key) == @paced_bytes

      # And the throttled client still gets every byte afterwards.
      assert {:ok, @paced_bytes} = collect(render)
    end
  end

  describe "disconnect policy" do
    test "with a store, the sole client leaving completes the render into it" do
      key = key()
      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(@paced))

      # Leave mid-render, on the render's own progress rather than a clock.
      assert_receive {:chunk, ^render, _data}, @deadline
      assert :ok = RenderCoordinator.unsubscribe(render)

      wait_until(fn -> match?({:ok, _entry}, VariantStore.head(key)) end)
      assert stored!(key) == @paced_bytes
    end

    test "without a store, the sole client leaving cancels, as before", %{root: root} do
      put_config(%{variant_store: nil})

      key = key()
      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(["sleep", "30"]))
      coordinator = Process.monitor(render)

      assert :ok = RenderCoordinator.unsubscribe(render)

      # The coordinator is gone — nothing was left subscribed to keep it —
      # and nothing was ever staged or stored.
      assert_receive {:DOWN, ^coordinator, :process, ^render, _reason}, @deadline
      assert File.ls!(root) == []
    end
  end

  describe "atomic or absent" do
    test "a mid-render failure leaves nothing readable and nothing staged", %{root: root} do
      key = key()
      failing = ["emit", "63", "sleep", "0.2", "stderr", "boom", "exit", "3"]
      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(failing))

      assert {:error, %{exit_status: 3}} = collect(render)

      wait_until(fn -> File.ls(Path.join(root, "tmp")) in [{:ok, []}, {:error, :enoent}] end)
      assert {:error, :not_found} = VariantStore.head(key)
    end

    test "a cancelled render leaves nothing readable and nothing staged", %{root: root} do
      key = key()

      {:ok, :miss, render, []} =
        RenderCoordinator.subscribe(key, spec(["emit", "63", "sleep", "30"]))

      # The tee is staging by now — the first chunk has been broadcast.
      assert_receive {:chunk, ^render, _data}, @deadline
      wait_until(fn -> match?({:ok, [_ | _]}, File.ls(Path.join(root, "tmp"))) end)

      # Shutdown mid-render — the way a stopping node cancels, not a client.
      coordinator = Process.monitor(render)

      :ok =
        DynamicSupervisor.terminate_child(AudioProxy.RenderCoordinator.Supervisor, render)

      assert_receive {:DOWN, ^coordinator, :process, ^render, _reason}, @deadline

      wait_until(fn -> File.ls!(Path.join(root, "tmp")) == [] end)
      assert {:error, :not_found} = VariantStore.head(key)
    end

    test "a write failure is instrumented and invisible to the client", %{root: root} do
      key = key()
      test = self()

      handler_id = {:tee_test, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          AudioProxy.Telemetry.store_write_failure_event(),
          fn _event, _measurements, metadata, _config ->
            send(test, {:write_failure, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # The store refuses writes from the first touch; the render must not care.
      File.chmod!(root, 0o555)
      on_exit(fn -> File.chmod!(root, 0o755) end)

      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(@paced))

      assert {:ok, @paced_bytes} = collect(render)

      assert_receive {:write_failure, %{key: ^key, reason: :eacces}}, @deadline

      File.chmod!(root, 0o755)
      assert {:error, :not_found} = VariantStore.head(key)
    end
  end
end
