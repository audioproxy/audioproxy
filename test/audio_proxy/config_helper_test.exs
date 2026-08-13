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

    test "is not itself guarded, because put_config/1 is the chokepoint" do
      # byte_limits/1 builds a map and installs nothing, so a key that never
      # reaches put_config/1 or base_config/1 is nobody's mistake yet.
      assert byte_limits(probe_timout: 1).probe_timout == 1
    end

    test "is the floor AudioProxy.SignedRequest.base_config/1 is built on" do
      # The direction of the dependency, asserted rather than assumed: the
      # signing floor adds key material to this one, so the limits have a
      # single definition and cannot drift.
      config = AudioProxy.SignedRequest.base_config(local_root: "/tmp/x")

      assert Map.take(config, [:max_src_bytes, :max_variant_bytes]) == byte_limits()
    end
  end

  describe "validate_keys!/2" do
    test "put_config/1 refuses a key nothing reads, naming it and the caller" do
      # The whole point: :probe_timout merges cleanly and leaves :probe_timeout
      # at whatever the environment gave it, so the failure would otherwise
      # arrive somewhere far from the typo.
      error =
        assert_raise ArgumentError, fn ->
          put_config(%{probe_timout: 1})
        end

      message = error.message

      assert message =~ ":probe_timout"
      assert message =~ "put_config/1"
    end

    test "the message suggests the nearest known key" do
      # Asserting that the suggestion is there and names the right key, not the
      # sentence around it — the wording is meant to be editable.
      error = assert_raise ArgumentError, fn -> put_config(%{probe_timout: 1}) end
      message = error.message

      assert message =~ ":probe_timeout"
    end

    test "a key too far from anything known is named without a guess" do
      # Below the jaro threshold nothing is suggested: a wrong suggestion sends
      # the reader somewhere worse than no suggestion at all.
      error = assert_raise ArgumentError, fn -> put_config(%{wibble: 1}) end
      message = error.message

      assert message =~ ":wibble"
      refute message =~ "did you mean"
    end

    test "a known key is installed unchanged" do
      put_config(%{serve_mode: :proxy})

      assert Config.get(:serve_mode) == :proxy
    end

    test "a typo inside the :s3 group is caught too" do
      # The group whose key names are least familiar, and the one a top-level
      # check would wave through.
      error =
        assert_raise ArgumentError, fn ->
          put_config(%{s3: %{endpiont: "http://localhost:9000"}})
        end

      message = error.message

      assert message =~ ":endpiont"
      assert message =~ ":endpoint"
    end

    test "a typo inside a keyword-list :s3 is caught the same way" do
      # base_config/1 takes keyword() | map() and converts only the top level,
      # so a caller writing the whole override in keyword syntax — which the
      # spec invites — used to slip a nested typo past both guards and land a
      # keyword list where Config keeps a map.
      error =
        assert_raise ArgumentError, fn ->
          AudioProxy.SignedRequest.base_config(local_root: "/tmp/x", s3: [endpiont: "http://x"])
        end

      assert error.message =~ ":endpiont"
    end

    test "an :s3 key written at the top level is told where it belongs" do
      # Spelled correctly, so jaro sees nothing wrong with it. The mistake is
      # the nesting, and that is what the message has to name.
      error = assert_raise ArgumentError, fn -> put_config(%{endpoint: "http://x"}) end

      assert error.message =~ ":endpoint"
      assert error.message =~ "s3:"
    end

    test "every unknown key is reported, not just the first" do
      error = assert_raise ArgumentError, fn -> put_config(%{probe_timout: 1, wibble: 2}) end

      assert error.message =~ ":probe_timout"
      assert error.message =~ ":wibble"
    end

    test "a non-atom key is named rather than crashing the suggestion" do
      # Atom.to_string/1 on a string key raised from inside the helper, which
      # replaced the guard's message with an unrelated one.
      error = assert_raise ArgumentError, fn -> put_config(%{"probe_timout" => 1}) end

      assert error.message =~ "probe_timout"
      assert error.message =~ "put_config/1"
    end

    test "a real :s3 key is not" do
      put_config(%{s3: %{Config.get(:s3) | addressing: :path}})

      assert Config.get(:s3).addressing == :path
    end

    test "base_config/1 refuses the key at the call site that wrote it" do
      error =
        assert_raise ArgumentError, fn ->
          AudioProxy.SignedRequest.base_config(local_root: "/tmp/x", probe_timout: 1)
        end

      message = error.message

      assert message =~ ":probe_timout"
      assert message =~ "base_config/1"
    end

    test "every key AudioProxy.Config defines is accepted" do
      # Derived, not restated. Precisely: a hard-coded list that has fallen
      # behind `Config` fails here — which is the day the drift starts to
      # matter, not the day the list is written. A new setting is overridable
      # with no edit to the support layer, and this is what says so.
      reference = Config.build!(%{})

      assert :ok = validate_keys!(reference, "test")
      assert :ok = validate_keys!(%{s3: reference.s3}, "test")
    end
  end
end
