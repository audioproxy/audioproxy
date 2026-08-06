defmodule AudioProxy.Config do
  @moduledoc """
  Runtime configuration, read from `AP_`-prefixed environment variables.

  The variable surface is defined by `docs/audio-proxy-api-v1.md` §6. Values are
  parsed and validated exactly once, during `AudioProxy.Application.start/2`, and
  stored in `:persistent_term` — reads on the request path are then a cheap
  global lookup with no GenServer in the way.

  Malformed values raise `AudioProxy.Config.Error` at boot, so a misconfigured
  container fails immediately instead of serving traffic with surprising
  defaults. Every error message names the offending variable.

  ## Variables

  | Variable | Type | Default |
  |---|---|---|
  | `AP_KEY` | hex-encoded binary, ≥ 32 bytes decoded | unset (`nil`) |
  | `AP_SALT` | hex-encoded binary | unset (`nil`) |
  | `AP_ALLOW_INSECURE` | boolean | `false` |
  | `AP_SOURCE_ALLOWLIST` | comma-separated list | `[]` |
  | `AP_LOCAL_ROOT` | existing directory, not `/` | unset (`nil`) — local sources disabled |
  | `AP_VARIANT_STORE` | scheme-tagged URL (`file:///path`, `s3://bucket`) | unset (`nil`) — no variant cache |
  | `AP_MAX_CONCURRENCY` | positive integer | `System.schedulers_online/0` |
  | `AP_QUEUE_SIZE` | non-negative integer | `32` |
  | `AP_READY_QUEUE_THRESHOLD` | non-negative integer, ≤ `AP_QUEUE_SIZE` | half the queue, floored, min 1 (`0` disables) |
  | `AP_MAX_SRC_BYTES` | positive integer | `2_000_000_000` |
  | `AP_MAX_VARIANT_BYTES` | positive integer | the effective `AP_MAX_SRC_BYTES` |
  | `AP_RENDER_TIMEOUT` | positive integer (seconds) | `300` |
  | `AP_PROBE_TIMEOUT` | positive integer (seconds) | `10` |
  | `AP_SERVE_MODE` | `redirect` \\| `proxy` | `:redirect` |
  | `AP_PRESIGN_TTL` | positive integer (seconds) | `300` |
  | `AP_LOG_LEVEL` | `debug` \\| `info` \\| `warning` \\| `error` | `:info` |
  | `AP_S3_ENDPOINT` | `http(s)://host[:port]` | unset (`nil`) — AWS proper |

  The listener port is read from `AP_PORT`, falling back to `PORT` (which the
  worktree workflow sets to the branch's hashed port), then to `4000`.

  ## The AWS variables

  S3 credentials are the one thing here **not** `AP_`-prefixed:
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and
  `AWS_REGION` (or `AWS_DEFAULT_REGION`). Every tool that produces credentials
  already writes those names, and renaming them would mean an operator
  translating a working environment into this proxy's dialect for no gain.

  They are read *here* rather than left to `ex_aws`'s own resolution, which
  would otherwise reach into application env and, on EC2, into IMDS. Keeping
  them in this map means the whole configuration surface is still one thing,
  validated once, at boot — and that what the proxy will use is what the
  operator set, not whatever a metadata endpoint happened to answer.
  `AudioProxy.S3` hands them to `ex_aws` per request.

  Validated all-or-nothing: a half-configured client fails at its first
  request instead of at boot, which is the failure this module exists to
  prevent.
  """

  defmodule Error do
    @moduledoc "Raised when an `AP_`-prefixed variable holds an unusable value."
    defexception [:message]
  end

  @storage_key __MODULE__

  # RFC 2104 §3 recommends an HMAC key at least as long as the hash output
  # (32 bytes for SHA-256); a shorter key caps the effective security at its
  # own length, so anything below the recommendation is rejected at boot.
  @min_key_bytes 32

  @default_port 4000
  @default_queue_size 32
  @default_max_src_bytes 2_000_000_000
  @default_render_timeout 300
  @serve_modes [:redirect, :proxy]

  # A probe reads container headers and stops; it never decodes a stream, so it
  # has no reason to share the render budget. Short on purpose: `/info` sits in
  # front of a player deciding what to request, and a source that cannot answer
  # in ten seconds is one the client should hear about rather than wait on.
  @default_probe_timeout 10

  # How long a HIT's presigned URL stays valid. Short on purpose: the URL is
  # handed to one client for one playback, and the response carrying it is
  # `no-store`, so nothing needs it to outlive the redirect it arrived in.
  @default_presign_ttl 300

  # Logger's own levels, narrowed to the four an operator has a reason to pick.
  # `:notice` and friends exist in OTP's scale but nothing here emits them, so
  # offering them would only be a way to configure a level with no meaning.
  @log_levels [:debug, :info, :warning, :error]
  @default_log_level :info

  # The two ways an S3 request can name its bucket. `:virtual` puts it in the
  # host (`bucket.host/key`), `:path` in the path (`host/bucket/key`). No
  # third style exists today, but the enum leaves room for one — and reads
  # better in a config table than a boolean whose default depends on another
  # variable.
  @s3_addressing_styles [:virtual, :path]

  # The key prefix the `s3://` boot probe writes under. Neither the leading
  # dot nor the slash is in `AudioProxy.CacheKey`'s alphabet, and
  # `AudioProxy.VariantStore.S3` refuses anything that is not a cache key — so
  # this names an object no variant can ever be stored as.
  @store_probe_prefix ".audio-proxy-boot-probe/"

  @truthy ~w(1 true yes on)
  @falsy ~w(0 false no off)

  @type t :: %{
          port: pos_integer(),
          key: binary() | nil,
          salt: binary() | nil,
          allow_insecure: boolean(),
          source_allowlist: [String.t()],
          local_root: String.t() | nil,
          variant_store: AudioProxy.VariantStore.config() | nil,
          max_concurrency: pos_integer(),
          queue_size: non_neg_integer(),
          ready_queue_threshold: non_neg_integer(),
          max_src_bytes: pos_integer(),
          max_variant_bytes: pos_integer(),
          render_timeout: pos_integer(),
          probe_timeout: pos_integer(),
          serve_mode: :redirect | :proxy,
          presign_ttl: pos_integer(),
          log_level: :debug | :info | :warning | :error,
          s3: s3()
        }

  @typedoc """
  The S3 settings, as one group.

  All of `region`, `access_key_id` and `secret_access_key` are `nil` together
  when S3 is not configured — the partial set is refused at boot, so anything
  that finds one of them finds all three.

  `addressing` and `ca_bundle` are independent of the credentials: both have a
  usable value whether or not S3 is configured at all.
  """
  @type s3 :: %{
          region: String.t() | nil,
          access_key_id: String.t() | nil,
          secret_access_key: String.t() | nil,
          session_token: String.t() | nil,
          endpoint: URI.t() | nil,
          addressing: :virtual | :path,
          ca_bundle: String.t() | nil
        }

  @doc """
  Parses and validates the environment, then stores the result for `all/0`.

  Called from `AudioProxy.Application.start/2`. Raises `Error` on the first
  unusable value.
  """
  @spec load!(map()) :: t()
  def load!(env \\ System.get_env()) do
    env |> build!() |> put_all() |> probe_store!()
  end

  @doc """
  Builds a validated config map from an environment map, without storing it.

  This is the function tests exercise for parsing and validation. It writes
  nothing to `:persistent_term`; it does touch the filesystem where a value
  *is* a filesystem claim — `AP_LOCAL_ROOT` must be an existing directory,
  and a `file://` variant store is probed for writability.

  It does **not** touch the network. An `s3://` variant store is parsed and
  shape-checked here and probed by `load!/1`, after the config is stored —
  because the probe is an S3 request, and `AudioProxy.S3` reads its
  credentials, endpoint and addressing from the very map being built. The
  asymmetry with the `file://` probe is that one: a path is provable from
  itself, a bucket is not.
  """
  @spec build!(map()) :: t()
  def build!(env) when is_map(env) do
    # Resolved before the map so `AP_MAX_VARIANT_BYTES` can fall back to the
    # *effective* source ceiling rather than to the shipped default: an operator
    # who already raised `AP_MAX_SRC_BYTES` to accept large masters keeps the
    # retention bound they have today instead of being silently tightened.
    # Resolving here, once, also keeps the coordinator's hot path reading one
    # number with no fallback logic in it.
    max_src_bytes = integer(env, "AP_MAX_SRC_BYTES", @default_max_src_bytes, :positive)

    # Read ahead of the map for the same shape of reason: the default for
    # `AP_READY_QUEUE_THRESHOLD` is a fraction of the queue, and a fixed number
    # would be unreachable under a small queue and trip far too late under a
    # large one.
    queue_size = integer(env, "AP_QUEUE_SIZE", @default_queue_size, :non_negative)

    validate!(%{
      port: port(env),
      key: hex(env, "AP_KEY", @min_key_bytes),
      salt: hex(env, "AP_SALT"),
      allow_insecure: boolean(env, "AP_ALLOW_INSECURE", false),
      source_allowlist: list(env, "AP_SOURCE_ALLOWLIST"),
      local_root: directory(env, "AP_LOCAL_ROOT"),
      variant_store: store(env, "AP_VARIANT_STORE"),
      max_concurrency: integer(env, "AP_MAX_CONCURRENCY", System.schedulers_online(), :positive),
      queue_size: queue_size,
      ready_queue_threshold:
        integer(
          env,
          "AP_READY_QUEUE_THRESHOLD",
          default_ready_queue_threshold(queue_size),
          :non_negative
        ),
      max_src_bytes: max_src_bytes,
      max_variant_bytes: integer(env, "AP_MAX_VARIANT_BYTES", max_src_bytes, :positive),
      render_timeout: integer(env, "AP_RENDER_TIMEOUT", @default_render_timeout, :positive),
      probe_timeout: integer(env, "AP_PROBE_TIMEOUT", @default_probe_timeout, :positive),
      serve_mode: enum(env, "AP_SERVE_MODE", @serve_modes, :redirect),
      presign_ttl: integer(env, "AP_PRESIGN_TTL", @default_presign_ttl, :positive),
      log_level: enum(env, "AP_LOG_LEVEL", @log_levels, @default_log_level),
      s3: s3(env)
    })
  end

  @doc "Returns the whole stored config."
  @spec all() :: t()
  def all, do: :persistent_term.get(@storage_key)

  @doc "Returns one stored config value."
  @spec get(atom()) :: term()
  def get(key) when is_atom(key), do: Map.fetch!(all(), key)

  @doc """
  Replaces the stored config wholesale.

  Used by `load!/1` at boot and by `AudioProxy.ConfigHelper` in tests. Nothing on
  the request path should call this.
  """
  @spec put_all(t()) :: t()
  def put_all(config) when is_map(config) do
    :persistent_term.put(@storage_key, config)
    config
  end

  @doc "The serve modes `AP_SERVE_MODE` accepts."
  @spec serve_modes() :: [atom()]
  def serve_modes, do: @serve_modes

  @doc "The levels `AP_LOG_LEVEL` accepts."
  @spec log_levels() :: [atom()]
  def log_levels, do: @log_levels

  @doc "The addressing styles `AP_S3_ADDRESSING` accepts."
  @spec s3_addressing_styles() :: [atom()]
  def s3_addressing_styles, do: @s3_addressing_styles

  ## Parsers

  # Half the queue: deep enough that a node shrugging off a burst is not
  # instantly ejected, shallow enough that the orchestrator learns about the
  # backlog well before the queue is full and requests start becoming 429s.
  # A queue of zero has no depth to measure, so readiness is disabled rather
  # than permanently tripped by a gauge that can only ever read `0`.
  defp default_ready_queue_threshold(0), do: 0
  defp default_ready_queue_threshold(queue_size), do: max(1, div(queue_size, 2))

  defp port(env) do
    cond do
      value = fetch(env, "AP_PORT") -> parse_integer!("AP_PORT", value, :positive)
      value = fetch(env, "PORT") -> parse_integer!("PORT", value, :positive)
      true -> @default_port
    end
  end

  defp hex(env, var, min_bytes \\ 0) do
    with value when is_binary(value) <- fetch(env, var) do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} ->
          if byte_size(decoded) >= min_bytes do
            decoded
          else
            raise Error,
                  "#{var} must decode to at least #{min_bytes} bytes (≥ #{min_bytes * 2} hex characters), got #{byte_size(decoded)} bytes"
          end

        :error ->
          raise Error,
                "#{var} must be hex-encoded (an even number of characters in 0-9a-fA-F), got: #{inspect(value)}"
      end
    end
  end

  defp boolean(env, var, default) do
    with value when is_binary(value) <- fetch(env, var) do
      downcased = String.downcase(value)

      cond do
        downcased in @truthy ->
          true

        downcased in @falsy ->
          false

        true ->
          raise Error,
                "#{var} must be one of #{inspect(@truthy ++ @falsy)}, got: #{inspect(value)}"
      end
    else
      nil -> default
    end
  end

  defp list(env, var) do
    case fetch(env, var) do
      nil ->
        []

      value ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  # `AP_VARIANT_STORE` is a scheme-tagged URL, parsed the way a source is:
  # the scheme picks the backend, the rest is the backend's address. Rejected
  # here rather than at first use so a container pointed at a store it cannot
  # write fails to boot instead of rendering everything twice, silently.
  defp store(env, var) do
    with value when is_binary(value) <- fetch(env, var) do
      case URI.new(value) do
        # A query or fragment has no meaning here; dropping one silently
        # would leave the operator believing it did something.
        {:ok, %URI{scheme: "file", query: query, fragment: fragment}}
        when is_binary(query) or is_binary(fragment) ->
          raise Error,
                "#{var} must be a bare directory URL with no query or fragment, got: #{inspect(value)}"

        {:ok, %URI{scheme: "file", host: host, path: path}}
        when host in [nil, ""] and is_binary(path) and path != "" ->
          store_directory!(var, value, path)

        # `file://var/cache` parses `var` as a *host* — an easy two-slash typo
        # that would otherwise fail as a nonexistent directory named `/cache`.
        {:ok, %URI{scheme: "file", host: host}} when is_binary(host) and host != "" ->
          raise Error,
                "#{var} file URLs take three slashes (file:///path); #{inspect(value)} reads #{inspect(host)} as a host"

        # The same refusal as the `file://` branch above, for the same reason:
        # a query or fragment means nothing to a bucket, and dropping one
        # silently would leave the operator believing it did something.
        {:ok, %URI{scheme: "s3", query: query, fragment: fragment}}
        when is_binary(query) or is_binary(fragment) ->
          raise Error,
                "#{var} must be a bare bucket URL with no query or fragment, got: #{inspect(value)}"

        # Refused for the sharper version of the query/fragment reason, and the
        # same one `s3_endpoint/2` gives twenty lines down: S3 credentials come
        # from the AWS variables and nothing reads userinfo, so
        # `s3://KEY:SECRET@bucket` would look to an operator like credentials
        # supplied and behave like credentials omitted — failing later as a
        # signature error that names nothing. The message does not echo the
        # value, so a boot failure cannot put a secret in a log.
        {:ok, %URI{scheme: "s3", userinfo: userinfo}} when is_binary(userinfo) ->
          raise Error,
                "#{var} must not carry credentials — S3 credentials come from AWS_ACCESS_KEY_ID " <>
                  "and AWS_SECRET_ACCESS_KEY, and userinfo here would be silently ignored"

        # A port names an endpoint, and the endpoint is `AP_S3_ENDPOINT`'s.
        # Accepting one here would drop it and address the store somewhere else
        # entirely.
        {:ok, %URI{scheme: "s3", port: port}} when is_integer(port) ->
          raise Error,
                "#{var} s3 URLs name a bucket only; a port belongs in AP_S3_ENDPOINT, got: #{inspect(value)}"

        {:ok, %URI{scheme: "s3", host: bucket, path: path}}
        when is_binary(bucket) and bucket != "" and path in [nil, "", "/"] ->
          {:s3, bucket!(var, value, bucket)}

        # A key prefix would have to be prepended to every cache key and
        # stripped from every lookup, and nothing here does either — so
        # `s3://bucket/variants` would quietly cache into `bucket` and ignore
        # the half the operator wrote it for.
        {:ok, %URI{scheme: "s3", host: bucket}} when is_binary(bucket) and bucket != "" ->
          raise Error,
                "#{var} s3 URLs name a bucket and nothing else (s3://bucket); a key prefix is not supported, got: #{inspect(value)}"

        {:ok, %URI{scheme: "s3"}} ->
          raise Error, "#{var} must name a bucket (s3://bucket), got: #{inspect(value)}"

        {:ok, %URI{scheme: scheme}} ->
          raise Error,
                "#{var} must be a scheme-tagged URL (file:///path or s3://bucket), got scheme #{inspect(scheme)} in #{inspect(value)}"

        {:error, _part} ->
          raise Error,
                "#{var} must be a scheme-tagged URL (file:///path or s3://bucket), got: #{inspect(value)}"
      end
    end
  end

  # The S3 group, parsed together because it only means anything together. An
  # access key with no secret, or either with no region, cannot sign — and
  # refusing the partial set at boot turns a run of 500s on the first S3
  # request into a container that does not start.
  defp s3(env) do
    id = fetch(env, "AWS_ACCESS_KEY_ID")
    secret = fetch(env, "AWS_SECRET_ACCESS_KEY")
    region = fetch(env, "AWS_REGION") || fetch(env, "AWS_DEFAULT_REGION")

    credentials!(id, secret, region)

    endpoint = s3_endpoint(env, "AP_S3_ENDPOINT")

    %{
      region: region,
      access_key_id: id,
      secret_access_key: secret,
      session_token: fetch(env, "AWS_SESSION_TOKEN"),
      endpoint: endpoint,
      addressing:
        enum(env, "AP_S3_ADDRESSING", @s3_addressing_styles, default_addressing(endpoint)),
      ca_bundle: readable_file(env, "AP_S3_CA_BUNDLE")
    }
  end

  # The asymmetry is the point. No endpoint means AWS, where virtual-hosted is
  # what regions launched after 2019 accept at all. An endpoint means an
  # S3-compatible store, and every one this project documents — MinIO, Ceph,
  # B2, DigitalOcean, Scaleway, Hetzner — is working today on path-style.
  # Defaulting a custom endpoint to virtual-hosted would break every existing
  # deployment to fix one that does not exist yet.
  defp default_addressing(nil), do: :virtual
  defp default_addressing(%URI{}), do: :path

  defp credentials!(nil, nil, _region), do: :ok

  defp credentials!(id, secret, region) do
    cond do
      is_nil(id) or is_nil(secret) ->
        raise Error,
              "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set together — one without the other cannot sign a request"

      # Signing is region-scoped: the region is inside the credential scope,
      # so a wrong or missing one is a signature every store rejects. There is
      # no safe default to guess, least of all against a non-AWS endpoint.
      is_nil(region) ->
        raise Error,
              "AWS_REGION (or AWS_DEFAULT_REGION) must be set when AWS credentials are — it is part of every signature"

      true ->
        :ok
    end
  end

  # An origin and nothing more: the path is decided per request by the
  # addressing style, so a path here would either be ignored or silently
  # prefixed onto every key. Both are worse than refusing it.
  #
  # Userinfo is refused for the sharper version of the same reason. S3
  # credentials come from the AWS variables, and nothing downstream reads
  # userinfo — so `http://key:secret@minio:9000` would look to an operator
  # like credentials supplied and behave like credentials omitted, failing
  # later as a signature error that names nothing. The message does not echo
  # the value, so a boot failure cannot put a secret in a log.
  defp s3_endpoint(env, var) do
    with value when is_binary(value) <- fetch(env, var) do
      case URI.new(value) do
        {:ok, %URI{userinfo: userinfo}} when is_binary(userinfo) ->
          raise Error,
                "#{var} must not carry credentials — S3 credentials come from AWS_ACCESS_KEY_ID " <>
                  "and AWS_SECRET_ACCESS_KEY, and userinfo here would be silently ignored"

        {:ok, %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil} = uri}
        when scheme in ["http", "https"] and is_binary(host) and host != "" and
               path in [nil, "", "/"] ->
          %{uri | path: nil}

        _otherwise ->
          raise Error,
                "#{var} must be an origin URL with no path, query or fragment (http://minio:9000), got: #{inspect(value)}"
      end
    end
  end

  # Existence and writability are both proved at boot, and writability by the
  # exact write the store performs — a file created under `<root>/tmp` — not
  # by mode bits, which say nothing about read-only mounts.
  defp store_directory!(var, value, path) do
    expanded = Path.expand(path)

    # Same refusal, and the same accident, as AP_LOCAL_ROOT's: nobody types
    # `file:///` deliberately, but `file://${DIR}/` with `DIR` unset produces
    # exactly it — and a store rooted at `/` would fan its variants out into
    # the filesystem root.
    if expanded == "/" do
      raise Error,
            "#{var} must not be the filesystem root — point it at the directory you mean, e.g. file:///var/cache/audio_proxy"
    end

    unless File.dir?(expanded) do
      raise Error, "#{var} must name an existing directory, got: #{inspect(value)}"
    end

    probe =
      Path.join([expanded, "tmp", ".boot-probe-#{System.unique_integer([:positive])}"])

    with :ok <- File.mkdir_p(Path.dirname(probe)),
         :ok <- File.write(probe, ""),
         :ok <- File.rm(probe) do
      {:file, expanded}
    else
      {:error, reason} ->
        raise Error,
              "#{var} must name a writable directory, got: #{inspect(value)} (#{inspect(reason)})"
    end
  end

  # S3's own bounds, checked here so a typo fails at boot naming the variable
  # rather than three layers down as a signature the store rejects. The
  # character set is left to the store: the rules differ between AWS and its
  # compatibles, and refusing a name a store would have accepted is worse than
  # forwarding one it will not.
  #
  # The name arrives lowercased, because `URI` lowercases a host and this one is
  # written as one. Bucket names are lowercase everywhere a bucket can be
  # created today, so the only value this loses is a legacy uppercase AWS name
  # from before 2018 — and that one cannot be addressed virtual-hosted either.
  defp bucket!(_var, _value, bucket) when byte_size(bucket) in 3..63, do: bucket

  defp bucket!(var, value, _bucket) do
    raise Error, "#{var} bucket names are 3–63 characters, got: #{inspect(value)}"
  end

  # The `s3://` half of "validated at boot by the operation the store actually
  # needs". Runs from `load!/1` rather than `build!/1` — see `build!/1` for
  # why — and does what the `file://` branch does with a probe file: write,
  # then take it back, so a bucket that is reachable and readable but refuses
  # writes fails the container instead of discarding every write-back in
  # silence.
  #
  # The key is outside the cache-key alphabet, so the probe cannot collide
  # with a variant however unlucky the timing.
  defp probe_store!(%{variant_store: {:s3, bucket}} = config) do
    unless AudioProxy.S3.configured?() do
      raise Error,
            "AP_VARIANT_STORE=s3://#{bucket} needs AWS credentials — set AWS_ACCESS_KEY_ID, " <>
              "AWS_SECRET_ACCESS_KEY and AWS_REGION, or use a file:/// store"
    end

    # The probe is a real S3 request, and a real S3 request needs the `:httpc`
    # profile `AudioProxy.S3.HttpClient` drives — which `AudioProxy.Application`
    # starts *after* this, because it sizes the pool from the config being built
    # here. Starting it is idempotent, so asking for it rather than depending on
    # boot order is cheaper than the ordering constraint: without this the probe
    # exits with `noproc` from inside `:gen_server.call`, and the container dies
    # with a stack trace instead of the message this function exists to print.
    AudioProxy.S3.HttpClient.setup!(config.max_concurrency)

    key = @store_probe_prefix <> Integer.to_string(System.unique_integer([:positive]))

    # Not a `with`: the two failures are different failures and an operator
    # needs to be told which one happened. A refused *write* means the bucket
    # cannot back a variant store at all. A refused *delete* means it can — the
    # write worked — and that this probe just left an object behind, which a
    # crashloop would repeat once per attempt. Saying "refused the boot probe"
    # for both would send someone to check write permissions that are fine.
    case AudioProxy.S3.put_stream(bucket, key, []) do
      :ok ->
        case AudioProxy.S3.delete(bucket, key) do
          :ok ->
            config

          {:error, reason} ->
            raise Error,
                  "AP_VARIANT_STORE=s3://#{bucket} accepted the boot probe and would not let it " <>
                    "be removed (#{inspect(reason)}); the object is still at #{key} and these " <>
                    "credentials need DeleteObject as well as PutObject"
        end

      {:error, reason} ->
        raise Error,
              "AP_VARIANT_STORE must name a bucket this deployment can write, and " <>
                "s3://#{bucket} refused the boot probe write (#{inspect(reason)})"
    end
  end

  defp probe_store!(config), do: config

  # Every cross-field rule, in one place. Each stage takes the whole config and
  # returns it, so adding one is adding a line here rather than another clause
  # on a function that was already matching on two unrelated keys.
  defp validate!(config) do
    config
    |> validate_redirect_presign!()
    |> validate_ready_queue_threshold!()
  end

  # Cross-field: the semaphore never queues more than `AP_QUEUE_SIZE` waiters,
  # so a threshold above it is a readiness check that can never trip. Refused
  # at boot rather than left to be discovered as a `/ready` that answered 200
  # through an outage.
  defp validate_ready_queue_threshold!(
         %{ready_queue_threshold: threshold, queue_size: queue_size} = config
       ) do
    if threshold > queue_size do
      raise Error,
            "AP_READY_QUEUE_THRESHOLD (#{threshold}) must not exceed AP_QUEUE_SIZE (#{queue_size}) — " <>
              "queue depth cannot reach it, so /ready could never report the node as unready"
    end

    config
  end

  # Cross-field: redirect serving is a 302 to a presigned variant URL, which
  # only a backend with the `:presign` capability can produce. Refused at boot
  # — naming both variables, since either can resolve it — rather than failing
  # on every HIT.
  defp validate_redirect_presign!(
         %{serve_mode: :redirect, variant_store: {scheme, _} = store} = config
       ) do
    backend = AudioProxy.VariantStore.backend_for(store)

    if :presign in backend.capabilities() do
      config
    else
      raise Error,
            "AP_SERVE_MODE=redirect serves cache hits via presigned URLs, which a #{scheme}:// " <>
              "AP_VARIANT_STORE cannot produce; set AP_SERVE_MODE=proxy or use a store that can presign"
    end
  end

  defp validate_redirect_presign!(config), do: config

  # Checked here rather than on the request path so that a container pointed at
  # a directory that is not mounted fails to boot, instead of answering every
  # local source with a 404 that looks like a missing file.
  defp directory(env, var) do
    with value when is_binary(value) <- fetch(env, var) do
      expanded = Path.expand(value)

      cond do
        # Every relative path is "under" `/`, so a root of `/` is confinement
        # switched off. Nobody types it deliberately; `AP_LOCAL_ROOT=${DIR}/`
        # with `DIR` unset produces it, which is exactly why it fails loudly at
        # boot rather than serving the filesystem.
        expanded == "/" ->
          raise Error,
                "#{var} must not be the filesystem root — it would serve every file on the host; point it at the directory you mean to serve"

        not File.dir?(expanded) ->
          raise Error, "#{var} must be an existing directory, got: #{inspect(value)}"

        true ->
          expanded
      end
    end
  end

  # Readability is proved by reading, not by mode bits — which say nothing
  # about a secret mounted for another user or a path that is a directory. The
  # contents are discarded; `:ssl` reads the file itself on the first
  # handshake, and the point here is that a bad path fails at boot rather than
  # on the first upload, the same posture as `AP_LOCAL_ROOT`.
  defp readable_file(env, var) do
    with value when is_binary(value) <- fetch(env, var) do
      expanded = Path.expand(value)

      case File.read(expanded) do
        {:ok, _contents} ->
          expanded

        {:error, reason} ->
          raise Error,
                "#{var} must name a readable file, got: #{inspect(value)} (#{inspect(reason)})"
      end
    end
  end

  defp integer(env, var, default, bound) do
    case fetch(env, var) do
      nil -> default
      value -> parse_integer!(var, value, bound)
    end
  end

  defp enum(env, var, allowed, default) do
    case fetch(env, var) do
      nil ->
        default

      value ->
        Enum.find(allowed, fn candidate -> Atom.to_string(candidate) == value end) ||
          raise(
            Error,
            "#{var} must be one of #{inspect(Enum.map(allowed, &Atom.to_string/1))}, got: #{inspect(value)}"
          )
    end
  end

  defp parse_integer!(var, value, bound) do
    with {integer, ""} <- Integer.parse(value),
         true <- in_bound?(integer, bound) do
      integer
    else
      _ -> raise Error, "#{var} must be #{describe(bound)}, got: #{inspect(value)}"
    end
  end

  defp in_bound?(integer, :positive), do: integer > 0
  defp in_bound?(integer, :non_negative), do: integer >= 0

  defp describe(:positive), do: "a positive integer"
  defp describe(:non_negative), do: "a non-negative integer"

  # Treats an empty or whitespace-only value as unset, so `AP_KEY=` in a compose
  # file or shell profile means "no key" rather than "the empty key".
  defp fetch(env, var) do
    case Map.get(env, var) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end
end
