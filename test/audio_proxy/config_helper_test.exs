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
end
