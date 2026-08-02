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
  | `AP_VARIANT_STORE` | scheme-tagged URL (`file:///path`) | unset (`nil`) — no variant cache |
  | `AP_MAX_CONCURRENCY` | positive integer | `System.schedulers_online/0` |
  | `AP_QUEUE_SIZE` | non-negative integer | `32` |
  | `AP_MAX_SRC_BYTES` | positive integer | `2_000_000_000` |
  | `AP_RENDER_TIMEOUT` | positive integer (seconds) | `300` |
  | `AP_SERVE_MODE` | `redirect` \\| `proxy` | `:redirect` |
  | `AP_LOG_LEVEL` | `debug` \\| `info` \\| `warning` \\| `error` | `:info` |

  The listener port is read from `AP_PORT`, falling back to `PORT` (which the
  worktree workflow sets to the branch's hashed port), then to `4000`.
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

  # Logger's own levels, narrowed to the four an operator has a reason to pick.
  # `:notice` and friends exist in OTP's scale but nothing here emits them, so
  # offering them would only be a way to configure a level with no meaning.
  @log_levels [:debug, :info, :warning, :error]
  @default_log_level :info

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
          max_src_bytes: pos_integer(),
          render_timeout: pos_integer(),
          serve_mode: :redirect | :proxy,
          log_level: :debug | :info | :warning | :error
        }

  @doc """
  Parses and validates the environment, then stores the result for `all/0`.

  Called from `AudioProxy.Application.start/2`. Raises `Error` on the first
  unusable value.
  """
  @spec load!(map()) :: t()
  def load!(env \\ System.get_env()) do
    env |> build!() |> put_all()
  end

  @doc """
  Builds a validated config map from an environment map, without storing it.

  This is the function tests exercise for parsing and validation. It writes
  nothing to `:persistent_term`; it does touch the filesystem where a value
  *is* a filesystem claim — `AP_LOCAL_ROOT` must be an existing directory,
  and a `file://` variant store is probed for writability.
  """
  @spec build!(map()) :: t()
  def build!(env) when is_map(env) do
    validate!(%{
      port: port(env),
      key: hex(env, "AP_KEY", @min_key_bytes),
      salt: hex(env, "AP_SALT"),
      allow_insecure: boolean(env, "AP_ALLOW_INSECURE", false),
      source_allowlist: list(env, "AP_SOURCE_ALLOWLIST"),
      local_root: directory(env, "AP_LOCAL_ROOT"),
      variant_store: store(env, "AP_VARIANT_STORE"),
      max_concurrency: integer(env, "AP_MAX_CONCURRENCY", System.schedulers_online(), :positive),
      queue_size: integer(env, "AP_QUEUE_SIZE", @default_queue_size, :non_negative),
      max_src_bytes: integer(env, "AP_MAX_SRC_BYTES", @default_max_src_bytes, :positive),
      render_timeout: integer(env, "AP_RENDER_TIMEOUT", @default_render_timeout, :positive),
      serve_mode: enum(env, "AP_SERVE_MODE", @serve_modes, :redirect),
      log_level: enum(env, "AP_LOG_LEVEL", @log_levels, @default_log_level)
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

  ## Parsers

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

        {:ok, %URI{scheme: "s3"}} ->
          raise Error,
                "#{var} does not support s3:// yet (the S3 backend is a separate slice); use file:///path"

        {:ok, %URI{scheme: scheme}} ->
          raise Error,
                "#{var} must be a scheme-tagged URL (file:///path), got scheme #{inspect(scheme)} in #{inspect(value)}"

        {:error, _part} ->
          raise Error, "#{var} must be a scheme-tagged URL (file:///path), got: #{inspect(value)}"
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

  # Cross-field: redirect serving is a 302 to a presigned variant URL, which
  # only a backend with the `:presign` capability can produce. Refused at boot
  # — naming both variables, since either can resolve it — rather than failing
  # on every HIT.
  defp validate!(%{serve_mode: :redirect, variant_store: {scheme, _} = store} = config) do
    backend = AudioProxy.VariantStore.backend_for(store)

    if :presign in backend.capabilities() do
      config
    else
      raise Error,
            "AP_SERVE_MODE=redirect serves cache hits via presigned URLs, which a #{scheme}:// " <>
              "AP_VARIANT_STORE cannot produce; set AP_SERVE_MODE=proxy or use a store that can presign"
    end
  end

  defp validate!(config), do: config

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
