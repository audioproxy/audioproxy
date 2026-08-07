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
               variant_store: nil,
               max_concurrency: System.schedulers_online(),
               queue_size: 32,
               ready_queue_threshold: 16,
               max_src_bytes: 2_000_000_000,
               max_variant_bytes: 2_000_000_000,
               render_timeout: 300,
               probe_timeout: 10,
               serve_mode: :redirect,
               presign_ttl: 300,
               log_level: :info,
               metrics_bind: {127, 0, 0, 1},
               metrics_port: 9568,
               s3: %{
                 region: nil,
                 access_key_id: nil,
                 secret_access_key: nil,
                 session_token: nil,
                 endpoint: nil,
                 addressing: :virtual,
                 ca_bundle: nil
               }
             }
    end

    test "an empty value counts as unset" do
      assert Config.build!(%{"AP_VARIANT_STORE" => ""}).variant_store == nil
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
          "AP_RENDER_TIMEOUT" => "90",
          "AP_PRESIGN_TTL" => "60"
        })

      assert config.queue_size == 32
      assert config.max_concurrency == 4
      assert config.max_src_bytes == 1_048_576
      assert config.render_timeout == 90
      assert config.presign_ttl == 60
    end

    test "AP_MAX_VARIANT_BYTES defaults to the effective AP_MAX_SRC_BYTES" do
      # The upgrade path. An operator who raised the source ceiling to accept
      # large masters keeps the retention bound they have today, rather than
      # being tightened to the shipped 2 GB default behind their back.
      config = Config.build!(%{"AP_MAX_SRC_BYTES" => "3000000000"})

      assert config.max_src_bytes == 3_000_000_000
      assert config.max_variant_bytes == 3_000_000_000
    end

    test "AP_MAX_VARIANT_BYTES set below the source ceiling is the retention bound" do
      # The split the change exists for: accept big inputs, produce small
      # outputs. The two numbers are independent once both are named.
      config =
        Config.build!(%{
          "AP_MAX_SRC_BYTES" => "3000000000",
          "AP_MAX_VARIANT_BYTES" => "268435456"
        })

      assert config.max_src_bytes == 3_000_000_000
      assert config.max_variant_bytes == 268_435_456
    end

    test "AP_MAX_VARIANT_BYTES above the source ceiling is allowed" do
      # Not a contradiction: a source of unknown size passes the stat check, so
      # a retention bound above the source ceiling is a coherent thing to want
      # and there is nothing to refuse.
      config =
        Config.build!(%{"AP_MAX_SRC_BYTES" => "1000", "AP_MAX_VARIANT_BYTES" => "2000"})

      assert config.max_variant_bytes == 2000
    end

    test "AP_QUEUE_SIZE accepts zero (no waiting, straight to 429)" do
      assert Config.build!(%{"AP_QUEUE_SIZE" => "0"}).queue_size == 0
    end

    test "AP_READY_QUEUE_THRESHOLD defaults to half the queue, whatever the queue is" do
      assert Config.build!(%{"AP_QUEUE_SIZE" => "64"}).ready_queue_threshold == 32
      assert Config.build!(%{"AP_QUEUE_SIZE" => "8"}).ready_queue_threshold == 4

      # Floored, but never to zero: a queue that can hold anything gets a
      # threshold that can trip.
      assert Config.build!(%{"AP_QUEUE_SIZE" => "1"}).ready_queue_threshold == 1
    end

    test "AP_QUEUE_SIZE of zero disables readiness, since there is no depth to read" do
      assert Config.build!(%{"AP_QUEUE_SIZE" => "0"}).ready_queue_threshold == 0
    end

    test "AP_READY_QUEUE_THRESHOLD accepts zero (readiness disabled)" do
      assert Config.build!(%{"AP_READY_QUEUE_THRESHOLD" => "0"}).ready_queue_threshold == 0
    end

    test "AP_READY_QUEUE_THRESHOLD is refused above AP_QUEUE_SIZE — it could never trip" do
      assert_raise Error, ~r/AP_READY_QUEUE_THRESHOLD \(9\).*AP_QUEUE_SIZE \(8\)/, fn ->
        Config.build!(%{"AP_QUEUE_SIZE" => "8", "AP_READY_QUEUE_THRESHOLD" => "9"})
      end
    end

    test "AP_READY_QUEUE_THRESHOLD is refused when negative" do
      assert_raise Error, ~r/AP_READY_QUEUE_THRESHOLD must be a non-negative integer/, fn ->
        Config.build!(%{"AP_READY_QUEUE_THRESHOLD" => "-1"})
      end
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

  describe "AP_METRICS_BIND and AP_METRICS_PORT" do
    test "default to loopback and the exporter port" do
      config = Config.build!(%{})

      # The scrape endpoint is unsigned, so its default reach is the whole of
      # its access control — and it must be a default nobody has to remember
      # to tighten.
      assert config.metrics_bind == {127, 0, 0, 1}
      assert config.metrics_port == 9568
    end

    test "an address literal becomes the tuple Bandit binds" do
      assert Config.build!(%{"AP_METRICS_BIND" => "0.0.0.0"}).metrics_bind == {0, 0, 0, 0}
      assert Config.build!(%{"AP_METRICS_BIND" => "::1"}).metrics_bind == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "a hostname is refused, since access control must not depend on DNS" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_METRICS_BIND" => "localhost"}) end

      assert error.message =~ "AP_METRICS_BIND"
      assert error.message =~ "not a hostname"
    end

    test "a port that is not a positive integer aborts naming the variable" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_METRICS_PORT" => "0"}) end

      assert error.message =~ "AP_METRICS_PORT"
    end

    test "a port equal to the listener's aborts, naming both variables" do
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_PORT" => "9568", "AP_METRICS_PORT" => "9568"})
        end

      assert error.message =~ "AP_METRICS_PORT"
      assert error.message =~ "AP_PORT"
    end

    test "the collision is caught against PORT too, which the worktree workflow sets" do
      # Not a hypothetical: `PORT` is the branch's hashed port, so a branch can
      # hash onto a metrics default nobody touched. Left to the runtime this is
      # an `:eaddrinuse` naming neither variable.
      assert_raise Error, fn -> Config.build!(%{"PORT" => "9568"}) end
    end

    test "the default pair does not collide" do
      config = Config.build!(%{})

      refute config.port == config.metrics_port
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

  describe "AP_VARIANT_STORE" do
    @describetag :tmp_dir

    test "is unset by default, which disables the variant cache" do
      assert Config.build!(%{}).variant_store == nil
    end

    test "a file:// URL parses to the local store, expanded", %{tmp_dir: tmp_dir} do
      config =
        Config.build!(%{"AP_VARIANT_STORE" => "file://#{tmp_dir}", "AP_SERVE_MODE" => "proxy"})

      assert config.variant_store == {:file, Path.expand(tmp_dir)}
    end

    test "an unknown scheme aborts, naming the variable" do
      error =
        assert_raise Error, fn -> Config.build!(%{"AP_VARIANT_STORE" => "gopher://cache"}) end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "gopher"
    end

    test "a value with no scheme at all aborts, naming the variable" do
      error =
        assert_raise Error, fn -> Config.build!(%{"AP_VARIANT_STORE" => "/var/cache/audio"}) end

      assert error.message =~ "AP_VARIANT_STORE"
    end

    test "an s3:// URL parses to the object store" do
      # `build!/1` does not probe the bucket — that is `load!/1`'s job and it
      # needs a network — so this is the parse, and only the parse.
      assert Config.build!(%{"AP_VARIANT_STORE" => "s3://variants"}).variant_store ==
               {:s3, "variants"}
    end

    test "an s3:// URL with a key prefix aborts rather than silently ignoring it" do
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_VARIANT_STORE" => "s3://variants/renders"})
        end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "key prefix"
    end

    test "an s3:// URL with a query or fragment aborts rather than dropping it" do
      for suffix <- ["?x=1", "#frag"] do
        error =
          assert_raise Error, fn ->
            Config.build!(%{"AP_VARIANT_STORE" => "s3://variants#{suffix}"})
          end

        assert error.message =~ "AP_VARIANT_STORE"
        assert error.message =~ "query or fragment"
      end
    end

    test "an s3:// URL carrying credentials aborts, and the message does not echo them" do
      # Silently dropping them would look to an operator like credentials
      # supplied and behave like credentials omitted — the same reasoning
      # AP_S3_ENDPOINT's userinfo refusal is built on.
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_VARIANT_STORE" => "s3://AKIAEXAMPLE:topsecret@variants"})
        end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "AWS_ACCESS_KEY_ID"
      refute error.message =~ "topsecret"
    end

    test "an s3:// URL with a port aborts rather than addressing somewhere else" do
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_VARIANT_STORE" => "s3://variants:9000"})
        end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "AP_S3_ENDPOINT"
    end

    test "an s3:// URL naming no bucket aborts" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_VARIANT_STORE" => "s3://"}) end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "bucket"
    end

    test "a bucket name S3 cannot have aborts at boot, not at the first signature" do
      error = assert_raise Error, fn -> Config.build!(%{"AP_VARIANT_STORE" => "s3://ab"}) end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "3"
    end

    test "redirect serving against an s3:// store is admitted, unchanged validator" do
      # The whole reason `AP_SERVE_MODE`'s documented default has been
      # unreachable: no shipped backend could presign. Both the explicit and
      # the defaulted mode, since the validator reads the effective one.
      for env <- [%{}, %{"AP_SERVE_MODE" => "redirect"}] do
        config = Config.build!(Map.put(env, "AP_VARIANT_STORE", "s3://variants"))

        assert config.serve_mode == :redirect
        assert config.variant_store == {:s3, "variants"}
      end
    end

    test "the two-slash file URL typo is caught as such, not as a missing directory" do
      error =
        assert_raise Error, fn -> Config.build!(%{"AP_VARIANT_STORE" => "file://var/cache"}) end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "three slashes"
    end

    test "a directory that is not there aborts, naming the variable" do
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_VARIANT_STORE" => "file:///nope/not/a/directory"})
        end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "existing directory"
    end

    test "the filesystem root aborts, since variants would fan out into /" do
      # `file://${DIR}/` with DIR unset spells exactly this.
      error = assert_raise Error, fn -> Config.build!(%{"AP_VARIANT_STORE" => "file:///"}) end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "filesystem root"
    end

    test "a query or fragment aborts rather than being silently dropped", %{tmp_dir: tmp_dir} do
      for suffix <- ["?x=1", "#frag"] do
        error =
          assert_raise Error, fn ->
            Config.build!(%{"AP_VARIANT_STORE" => "file://#{tmp_dir}#{suffix}"})
          end

        assert error.message =~ "AP_VARIANT_STORE"
        assert error.message =~ "query or fragment"
      end
    end

    test "a directory that refuses writes aborts, naming the variable", %{tmp_dir: tmp_dir} do
      File.chmod!(tmp_dir, 0o555)
      on_exit(fn -> File.chmod!(tmp_dir, 0o755) end)

      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_VARIANT_STORE" => "file://#{tmp_dir}", "AP_SERVE_MODE" => "proxy"})
        end

      assert error.message =~ "AP_VARIANT_STORE"
      assert error.message =~ "writable"
    end

    test "redirect serving against a file:// store aborts, naming both variables",
         %{tmp_dir: tmp_dir} do
      # Explicit and defaulted redirect alike: the effective mode is what the
      # store cannot satisfy, however it was arrived at.
      for env <- [%{}, %{"AP_SERVE_MODE" => "redirect"}] do
        error =
          assert_raise Error, fn ->
            Config.build!(Map.put(env, "AP_VARIANT_STORE", "file://#{tmp_dir}"))
          end

        assert error.message =~ "AP_SERVE_MODE"
        assert error.message =~ "AP_VARIANT_STORE"
      end
    end

    test "proxy serving against a file:// store is accepted", %{tmp_dir: tmp_dir} do
      config =
        Config.build!(%{"AP_VARIANT_STORE" => "file://#{tmp_dir}", "AP_SERVE_MODE" => "proxy"})

      assert config.serve_mode == :proxy
      assert {:file, _root} = config.variant_store
    end
  end

  describe "the AWS credential group" do
    @credentials %{
      "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
      "AWS_SECRET_ACCESS_KEY" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      "AWS_REGION" => "eu-central-1"
    }

    test "a complete set parses" do
      s3 = Config.build!(@credentials).s3

      assert s3.access_key_id == "AKIAIOSFODNN7EXAMPLE"
      assert s3.secret_access_key == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      assert s3.region == "eu-central-1"
      assert s3.session_token == nil
    end

    test "AWS_DEFAULT_REGION stands in for AWS_REGION" do
      env = @credentials |> Map.delete("AWS_REGION") |> Map.put("AWS_DEFAULT_REGION", "us-west-2")

      assert Config.build!(env).s3.region == "us-west-2"
    end

    test "AWS_REGION wins over AWS_DEFAULT_REGION" do
      assert Config.build!(Map.put(@credentials, "AWS_DEFAULT_REGION", "us-west-2")).s3.region ==
               "eu-central-1"
    end

    test "a session token is carried for temporary credentials" do
      assert Config.build!(Map.put(@credentials, "AWS_SESSION_TOKEN", "temp")).s3.session_token ==
               "temp"
    end

    test "an access key with no secret aborts" do
      # Half a credential signs nothing. Refusing at boot beats a container
      # that starts and then 500s on its first S3 request.
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE"})
        end

      assert error.message =~ "AWS_ACCESS_KEY_ID"
      assert error.message =~ "AWS_SECRET_ACCESS_KEY"
    end

    test "a secret with no access key aborts" do
      assert_raise Error, fn -> Config.build!(%{"AWS_SECRET_ACCESS_KEY" => "secret"}) end
    end

    test "credentials with no region abort" do
      # The region is inside the credential scope, so a missing one is a
      # signature every store rejects — and there is nothing safe to guess.
      error = assert_raise Error, fn -> Config.build!(Map.delete(@credentials, "AWS_REGION")) end

      assert error.message =~ "AWS_REGION"
    end

    test "a region alone is fine — it configures nothing on its own" do
      assert Config.build!(%{"AWS_REGION" => "eu-central-1"}).s3.access_key_id == nil
    end
  end

  describe "AP_S3_ENDPOINT" do
    test "an origin URL parses" do
      endpoint = Config.build!(%{"AP_S3_ENDPOINT" => "http://minio:9000"}).s3.endpoint

      assert endpoint.scheme == "http"
      assert endpoint.host == "minio"
      assert endpoint.port == 9000
    end

    test "a bare trailing slash is accepted and dropped" do
      assert Config.build!(%{"AP_S3_ENDPOINT" => "https://minio.internal/"}).s3.endpoint.path ==
               nil
    end

    test "a path is refused" do
      # It would either be ignored or silently prefixed onto every key; both
      # are worse than saying so.
      error =
        assert_raise Error, fn -> Config.build!(%{"AP_S3_ENDPOINT" => "http://minio:9000/s3"}) end

      assert error.message =~ "AP_S3_ENDPOINT"
    end

    test "a query or fragment is refused" do
      assert_raise Error, fn -> Config.build!(%{"AP_S3_ENDPOINT" => "http://minio:9000?a=1"}) end
      assert_raise Error, fn -> Config.build!(%{"AP_S3_ENDPOINT" => "http://minio:9000#a"}) end
    end

    test "a non-HTTP scheme is refused" do
      assert_raise Error, fn -> Config.build!(%{"AP_S3_ENDPOINT" => "s3://minio:9000"}) end
    end

    test "a value with no host is refused" do
      assert_raise Error, fn -> Config.build!(%{"AP_S3_ENDPOINT" => "minio:9000"}) end
    end

    test "userinfo is refused rather than silently dropped" do
      # Nothing downstream reads it, so credentials here would look supplied
      # and behave omitted — failing later as a signature error that names
      # nothing.
      error =
        assert_raise Error, fn ->
          Config.build!(%{"AP_S3_ENDPOINT" => "http://key:secret@minio:9000"})
        end

      assert error.message =~ "AP_S3_ENDPOINT"
      assert error.message =~ "AWS_ACCESS_KEY_ID"
      # The message must not echo the value, or a boot failure puts a secret
      # in the logs.
      refute error.message =~ "secret"
    end

    test "a bare username with no password is refused too" do
      assert_raise Error, fn -> Config.build!(%{"AP_S3_ENDPOINT" => "http://key@minio:9000"}) end
    end
  end

  describe "AP_S3_ADDRESSING" do
    test "defaults to virtual-hosted when no endpoint is set" do
      # AWS: path-style is deprecated there and regions launched after 2019
      # never supported it.
      assert Config.build!(%{}).s3.addressing == :virtual
    end

    test "defaults to path-style when an endpoint is set" do
      # Every S3-compatible provider this project documents is deployed on
      # path-style today; defaulting them to virtual-hosted would break all of
      # them to fix one deployment that does not exist yet.
      assert Config.build!(%{"AP_S3_ENDPOINT" => "http://minio:9000"}).s3.addressing == :path
    end

    test "the endpoint decides the default, not the absence of other variables" do
      # Pins the asymmetry itself: the same environment, differing only in
      # AP_S3_ENDPOINT, must yield the two different defaults. Without this a
      # default of :virtual everywhere would pass the test above.
      env = %{
        "AWS_ACCESS_KEY_ID" => "id",
        "AWS_SECRET_ACCESS_KEY" => "secret",
        "AWS_REGION" => "us-east-1"
      }

      assert Config.build!(env).s3.addressing == :virtual

      assert Config.build!(Map.put(env, "AP_S3_ENDPOINT", "https://s3.example")).s3.addressing ==
               :path
    end

    test "an explicit value overrides either default" do
      assert Config.build!(%{"AP_S3_ADDRESSING" => "path"}).s3.addressing == :path

      assert Config.build!(%{
               "AP_S3_ENDPOINT" => "http://minio:9000",
               "AP_S3_ADDRESSING" => "virtual"
             }).s3.addressing == :virtual
    end

    test "anything else is refused at boot" do
      error =
        assert_raise Error, fn -> Config.build!(%{"AP_S3_ADDRESSING" => "vhost"}) end

      assert error.message =~ "AP_S3_ADDRESSING"
      assert error.message =~ "virtual"
      assert error.message =~ "path"
    end

    test "the accepted styles are published for the docs and the router" do
      assert Config.s3_addressing_styles() == [:virtual, :path]
    end
  end

  describe "AP_S3_CA_BUNDLE" do
    @describetag :tmp_dir

    test "defaults to unset, meaning the system trust store", %{tmp_dir: _tmp_dir} do
      assert Config.build!(%{}).s3.ca_bundle == nil
    end

    test "a readable file is expanded and kept", %{tmp_dir: tmp_dir} do
      bundle = Path.join(tmp_dir, "ca.pem")
      File.write!(bundle, "-----BEGIN CERTIFICATE-----\n")

      assert Config.build!(%{"AP_S3_CA_BUNDLE" => bundle}).s3.ca_bundle == Path.expand(bundle)
    end

    test "a path that is not there is refused at boot", %{tmp_dir: tmp_dir} do
      # Rather than on the first upload, which is a TLS error naming a file
      # nobody would think to check.
      missing = Path.join(tmp_dir, "absent.pem")

      error = assert_raise Error, fn -> Config.build!(%{"AP_S3_CA_BUNDLE" => missing}) end

      assert error.message =~ "AP_S3_CA_BUNDLE"
      assert error.message =~ "readable file"
    end

    test "a directory is refused too", %{tmp_dir: tmp_dir} do
      # `File.read/1` on a directory answers :eisdir, which is exactly the
      # accident this catches: a bundle path pointing at the mount rather than
      # at the file inside it.
      assert_raise Error, fn -> Config.build!(%{"AP_S3_CA_BUNDLE" => tmp_dir}) end
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

    for var <-
          ~w(AP_MAX_CONCURRENCY AP_MAX_SRC_BYTES AP_MAX_VARIANT_BYTES AP_RENDER_TIMEOUT AP_PRESIGN_TTL AP_PORT PORT) do
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

      assert config.log_level in Config.log_levels()
      assert Config.get(:log_level) == config.log_level
    end

    test "get/1 raises for an unknown key" do
      assert_raise KeyError, fn -> Config.get(:nope) end
    end
  end
end
