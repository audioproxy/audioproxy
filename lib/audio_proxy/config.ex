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
  | `AP_VARIANT_BUCKET` | string | unset (`nil`) — no variant cache |
  | `AP_MAX_CONCURRENCY` | positive integer | `System.schedulers_online/0` |
  | `AP_QUEUE_SIZE` | non-negative integer | `32` |
  | `AP_MAX_SRC_BYTES` | positive integer | `2_000_000_000` |
  | `AP_RENDER_TIMEOUT` | positive integer (seconds) | `300` |
  | `AP_SERVE_MODE` | `redirect` \\| `proxy` | `:redirect` |

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

  @truthy ~w(1 true yes on)
  @falsy ~w(0 false no off)

  @type t :: %{
          port: pos_integer(),
          key: binary() | nil,
          salt: binary() | nil,
          allow_insecure: boolean(),
          source_allowlist: [String.t()],
          local_root: String.t() | nil,
          variant_bucket: String.t() | nil,
          max_concurrency: pos_integer(),
          queue_size: non_neg_integer(),
          max_src_bytes: pos_integer(),
          render_timeout: pos_integer(),
          serve_mode: :redirect | :proxy
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

  Pure — this is the function tests exercise for parsing and validation.
  """
  @spec build!(map()) :: t()
  def build!(env) when is_map(env) do
    %{
      port: port(env),
      key: hex(env, "AP_KEY", @min_key_bytes),
      salt: hex(env, "AP_SALT"),
      allow_insecure: boolean(env, "AP_ALLOW_INSECURE", false),
      source_allowlist: list(env, "AP_SOURCE_ALLOWLIST"),
      local_root: directory(env, "AP_LOCAL_ROOT"),
      variant_bucket: string(env, "AP_VARIANT_BUCKET"),
      max_concurrency: integer(env, "AP_MAX_CONCURRENCY", System.schedulers_online(), :positive),
      queue_size: integer(env, "AP_QUEUE_SIZE", @default_queue_size, :non_negative),
      max_src_bytes: integer(env, "AP_MAX_SRC_BYTES", @default_max_src_bytes, :positive),
      render_timeout: integer(env, "AP_RENDER_TIMEOUT", @default_render_timeout, :positive),
      serve_mode: serve_mode(env)
    }
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

  defp string(env, var), do: fetch(env, var)

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

  defp serve_mode(env) do
    case fetch(env, "AP_SERVE_MODE") do
      nil ->
        :redirect

      value ->
        Enum.find(@serve_modes, fn mode -> Atom.to_string(mode) == value end) ||
          raise(
            Error,
            "AP_SERVE_MODE must be one of #{inspect(Enum.map(@serve_modes, &Atom.to_string/1))}, got: #{inspect(value)}"
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
