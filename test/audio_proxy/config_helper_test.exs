defmodule AudioProxy.ConfigHelperTest do
  # Not async: put_config/1 swaps process-global state in :persistent_term.
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Config

  test "put_config/1 overrides only the given keys" do
    original = Config.all()

    put_config(%{serve_mode: :proxy, queue_size: 1})

    assert Config.get(:serve_mode) == :proxy
    assert Config.get(:queue_size) == 1
    assert Config.get(:port) == original.port
  end

  test "put_config/1 restores the previous config on exit" do
    original = Config.all()

    # on_exit callbacks run in reverse registration order, so this one runs
    # after the restore that put_config/1 registers below.
    on_exit(fn -> assert Config.all() == original end)

    put_config(%{serve_mode: :proxy})

    assert Config.get(:serve_mode) == :proxy
  end

  describe "byte_limits/1" do
    test "pins both limits and requires nothing" do
      # The floor a file takes when it signs nothing: an AP_MAX_SRC_BYTES in the
      # environment must not be able to reach the assertion through either key.
      assert byte_limits() == %{
               max_src_bytes: 2_000_000_000,
               max_variant_bytes: 2_000_000_000
             }
    end

    test "an override wins over the floor, and unrelated keys come along" do
      # The merge direction is the ergonomic argument: a file states the floor
      # and its subject in one expression, and the subject takes effect.
      limits = byte_limits(max_src_bytes: 10, variant_store: {:file, "/tmp/x"})

      assert limits.max_src_bytes == 10
      assert limits.max_variant_bytes == 2_000_000_000
      assert limits.variant_store == {:file, "/tmp/x"}
    end

    test "takes a map as readily as a keyword list" do
      assert byte_limits(%{max_src_bytes: 10}).max_src_bytes == 10
    end

    test "is the floor AudioProxy.SignedRequest.base_config/1 is built on" do
      # The direction of the dependency, asserted rather than assumed: the
      # signing floor adds key material to this one, so the limits have a
      # single definition and cannot drift.
      config = AudioProxy.SignedRequest.base_config(local_root: "/tmp/x")

      assert Map.take(config, [:max_src_bytes, :max_variant_bytes]) == byte_limits()
    end
  end
end
