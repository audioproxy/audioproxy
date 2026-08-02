defmodule AudioProxy.ConfigTest do
  use ExUnit.Case, async: true

  alias AudioProxy.Config
  alias AudioProxy.Config.Error

  describe "defaults" do
    test "an empty environment yields the documented defaults" do
      config = Config.build!(%{})

      assert config == %{
               port: 4000,
               key: nil,
               salt: nil,
               allow_insecure: false,
               source_allowlist: [],
               local_root: nil,
               variant_bucket: nil,
               max_concurrency: System.schedulers_online(),
               queue_size: 32,
               max_src_bytes: 2_000_000_000,
               render_timeout: 300,
               serve_mode: :redirect,
               log_level: :info
             }
    end

    test "an empty value counts as unset" do
      assert Config.build!(%{"AP_VARIANT_BUCKET" => ""}).variant_bucket == nil
      assert Config.build!(%{"AP_KEY" => "   "}).key == nil

      assert Config.build!(%{"AP_MAX_CONCURRENCY" => ""}).max_concurrency ==
               System.schedulers_online()
    end
  end

  describe "typed parsing" do
    test "integers are integers, not strings" do
      config =
        Config.build!(%{
          "AP_QUEUE_SIZE" => "32",
          "AP_MAX_CONCURRENCY" => "4",
          "AP_MAX_SRC_BYTES" => "1048576",
          "AP_RENDER_TIMEOUT" => "90"
        })

      assert config.queue_size == 32
      assert config.max_concurrency == 4
      assert config.max_src_bytes == 1_048_576
      assert config.render_timeout == 90
    end

    test "AP_QUEUE_SIZE accepts zero (no waiting, straight to 429)" do
      assert Config.build!(%{"AP_QUEUE_SIZE" => "0"}).queue_size == 0
    end

    test "hex key and salt are decoded to binaries" do
      key_hex = String.duplicate("ab", 32)
      config = Config.build!(%{"AP_KEY" => key_hex, "AP_SALT" => "00ff"})

      assert config.key == String.duplicate(<<0xAB>>, 32)
      assert config.salt == <<0x00, 0xFF>>
    end

    test "AP_KEY shorter than 32 bytes aborts, naming the variable" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_KEY" => "deadBEEF"}) end

      assert error.message =~ "AP_KEY"
      assert error.message =~ "at least 32 bytes"
    end

    test "booleans accept the usual spellings, case-insensitively" do
      for value <- ~w(1 true yes on TRUE Yes On) do
        assert Config.build!(%{"AP_ALLOW_INSECURE" => value}).allow_insecure == true
      end

      for value <- ~w(0 false no off FALSE No Off) do
        assert Config.build!(%{"AP_ALLOW_INSECURE" => value}).allow_insecure == false
      end
    end

    test "the allowlist splits on commas and trims whitespace" do
      config = Config.build!(%{"AP_SOURCE_ALLOWLIST" => "masters, cdn.example.com ,*.audio.test"})

      assert config.source_allowlist == ["masters", "cdn.example.com", "*.audio.test"]
    end

    test "empty allowlist entries are dropped" do
      assert Config.build!(%{"AP_SOURCE_ALLOWLIST" => "masters,,  ,previews"}).source_allowlist ==
               ["masters", "previews"]
    end

    test "serve mode becomes an atom" do
      assert Config.build!(%{"AP_SERVE_MODE" => "redirect"}).serve_mode == :redirect
      assert Config.build!(%{"AP_SERVE_MODE" => "proxy"}).serve_mode == :proxy
    end

    test "log level becomes an atom Logger accepts" do
      for level <- Config.log_levels() do
        assert Config.build!(%{"AP_LOG_LEVEL" => Atom.to_string(level)}).log_level == level
        assert level in Logger.levels()
      end
    end
  end

  describe "AP_LOCAL_ROOT" do
    @describetag :tmp_dir

    test "is unset by default, which disables local sources" do
      assert Config.build!(%{}).local_root == nil
    end

    test "is expanded to an absolute path", %{tmp_dir: tmp_dir} do
      relative = Path.relative_to_cwd(tmp_dir)

      assert Config.build!(%{"AP_LOCAL_ROOT" => relative}).local_root == Path.expand(tmp_dir)
    end

    test "a directory that is not there aborts the boot, naming the variable" do
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_LOCAL_ROOT" => "/nope/not/a/directory"})
        end

      assert error.message =~ "AP_LOCAL_ROOT"
      assert error.message =~ "directory"
    end

    test "the filesystem root aborts the boot, since it would serve the whole host" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_LOCAL_ROOT" => "/"}) end

      assert error.message =~ "AP_LOCAL_ROOT"
      assert error.message =~ "filesystem root"
    end

    test "a file rather than a directory aborts the boot", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "a-file")
      File.write!(file, "")

      assert_raise Error, fn -> Config.build!(%{"AP_LOCAL_ROOT" => file}) end
    end
  end

  describe "listener port" do
    test "defaults to 4000" do
      assert Config.build!(%{}).port == 4000
    end

    test "PORT is honoured for the worktree workflow" do
      assert Config.build!(%{"PORT" => "13042"}).port == 13_042
    end

    test "AP_PORT wins over PORT" do
      assert Config.build!(%{"AP_PORT" => "4001", "PORT" => "13042"}).port == 4001
    end
  end

  describe "validation" do
    test "non-hex AP_KEY aborts, naming the variable" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_KEY" => "not-hex"}) end

      assert error.message =~ "AP_KEY"
      assert error.message =~ "hex"
    end

    test "odd-length AP_SALT aborts, naming the variable" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_SALT" => "abc"}) end

      assert error.message =~ "AP_SALT"
    end

    test "unknown AP_SERVE_MODE aborts, listing the allowed values" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_SERVE_MODE" => "banana"}) end

      assert error.message =~ "AP_SERVE_MODE"
      assert error.message =~ "redirect"
      assert error.message =~ "proxy"
    end

    test "unknown AP_LOG_LEVEL aborts, listing the allowed values" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_LOG_LEVEL" => "verbose"}) end

      assert error.message =~ "AP_LOG_LEVEL"

      for level <- ~w(debug info warning error) do
        assert error.message =~ level
      end
    end

    test "non-boolean AP_ALLOW_INSECURE aborts, naming the variable" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_ALLOW_INSECURE" => "maybe"}) end

      assert error.message =~ "AP_ALLOW_INSECURE"
    end

    for var <- ~w(AP_MAX_CONCURRENCY AP_MAX_SRC_BYTES AP_RENDER_TIMEOUT AP_PORT PORT) do
      test "#{var} must be a positive integer" do
        for value <- ~w(0 -1 abc 1.5 12kb) do
          error = assert_raise Error, fn -> Config.build!(%{unquote(var) => value}) end

          assert error.message =~ unquote(var)
          assert error.message =~ "positive integer"
        end
      end
    end

    test "AP_QUEUE_SIZE must be a non-negative integer" do
      for value <- ~w(-1 abc 1.5) do
        error = assert_raise Error, fn -> Config.build!(%{"AP_QUEUE_SIZE" => value}) end

        assert error.message =~ "AP_QUEUE_SIZE"
        assert error.message =~ "non-negative integer"
      end
    end

    test "surrounding whitespace is tolerated, embedded garbage is not" do
      assert Config.build!(%{"AP_QUEUE_SIZE" => " 32 "}).queue_size == 32
      assert_raise Error, fn -> Config.build!(%{"AP_QUEUE_SIZE" => "3 2"}) end
    end
  end

  describe "stored config" do
    test "the booted application exposes a full config" do
      config = Config.all()

      assert is_integer(config.port)
      assert config.serve_mode in Config.serve_modes()
      assert Config.get(:serve_mode) == config.serve_mode
    end

    test "get/1 raises for an unknown key" do
      assert_raise KeyError, fn -> Config.get(:nope) end
    end
  end
end
