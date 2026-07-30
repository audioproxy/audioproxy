defmodule AudioProxy.CacheKey do
  @moduledoc """
  Variant identity: the object key under which a rendered variant is cached.

  A variant is exactly its normalized processing options plus the source it
  was rendered from, so the key is

      lowercase-hex(SHA-256(normalized-options ‖ "\\n" ‖ canonical-source))

  The newline separates the two halves unambiguously — a normalized options
  string never contains one, so no options/source pair can be confused with
  another. Equal variants therefore share a key regardless of segment order,
  and any differing option (`cb` included, since it survives normalization)
  yields a different one.

  The digest is flat and length-bounded, which is what an S3 object key wants;
  a human-debuggable prefix was considered and rejected (design).

      iex> AudioProxy.CacheKey.derive!("br:96/f:opus", "s3://masters/a.wav")
      ...> == AudioProxy.CacheKey.derive!("f:opus/br:96", "s3://masters/a.wav")
      true
  """

  alias AudioProxy.OptionError
  alias AudioProxy.Options

  @separator "\n"

  @typedoc "Lowercase hex SHA-256 digest, 64 characters."
  @type t :: String.t()

  @doc """
  Derives the cache key for `options` rendered from `source`.

  `options` may be an options string, a pre-split segment list, or an already
  parsed `t:AudioProxy.Options.t/0`; the first two are parsed and validated
  first, so an invalid options string surfaces its `OptionError` here rather
  than producing a key for a variant that cannot be rendered.

  `source` is the canonical source identity produced by the source resolver
  (e.g. `"s3://bucket/key"`) — this module does not canonicalize it.
  """
  @spec derive(Options.t() | String.t() | [String.t()], String.t()) ::
          {:ok, t()} | {:error, OptionError.t()}
  def derive(%Options{} = options, source) when is_binary(source) do
    {:ok, digest(Options.normalize(options), source)}
  end

  def derive(options, source) when is_binary(source) do
    with {:ok, normalized} <- Options.normalize_string(options) do
      {:ok, digest(normalized, source)}
    end
  end

  @doc """
  Like `derive/2`, raising `ArgumentError` when the options are invalid.

  For call sites that have already validated their options — tests, and the
  render path once the request has passed the options gate.
  """
  @spec derive!(Options.t() | String.t() | [String.t()], String.t()) :: t()
  def derive!(options, source) do
    case derive(options, source) do
      {:ok, key} -> key
      {:error, error} -> raise ArgumentError, OptionError.message(error)
    end
  end

  defp digest(normalized, source) do
    :sha256
    |> :crypto.hash(normalized <> @separator <> source)
    |> Base.encode16(case: :lower)
  end
end
