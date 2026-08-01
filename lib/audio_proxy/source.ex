defmodule AudioProxy.Source do
  @moduledoc """
  The source segment (API doc §1): encodings, decoding, dispatch, identity.

  The source is the tail of a signed path — everything after the options — and
  it arrives in one of two encodings:

    * `plain/{source}` — the source string, percent-escaped so it survives
      being carried as path bytes (`plain/s3://masters/a%20track.wav`).
    * `enc/{base64url(source)}` — the same source string, base64url-encoded,
      which exists so nested URLs never have to be escaped by hand.

  This module owns what those encodings imply, and deliberately nothing else.
  What a source *is* — a bucket and key, a URL, a path under a root — belongs
  to a source type (`AudioProxy.Source.Type`), and each type ships in its own
  slice. Ask this module to parse a source and it will decode, vet, and hand
  the remainder to whichever type claims the scheme.

  One type is registered: `local://`, files under `AP_LOCAL_ROOT`
  (`AudioProxy.Source.Local`). Anything else is `{:error, :unknown_scheme}`
  until `add-remote-files-source` adds `s3://` and `https://`.

  ## Decode exactly once

  The `enc/` form is decoded to the plain *source string* first, and from there
  both encodings share one code path — that is what keeps them from drifting
  semantically, and it fixes an ordering every type depends on: decode fully,
  *then* interpret. A path-confinement check or a URL parse is only sound on a
  fully-decoded string.

  It also fixes what "escaped" means. The `plain/` payload is percent-decoded
  exactly once, so a literal `%` is written `%25` and a literal space `%20`.
  `+` is left alone; it is a literal plus in a path, and the `+`-means-space
  convention belongs to query strings.

  Escapes must be well-formed. `%zz` is rejected rather than passed through,
  because passing it through would give one source two spellings (`%zz` and
  `%25zz` would both decode to `%zz`) and therefore one variant two cache keys.

  ## What is refused here, once, for everyone

  Control, format and line/paragraph-separator code points are refused in any
  decoded source, by Unicode category rather than by the ASCII range —
  `\\x00-\\x1f` alone lets U+0085, U+2028 and U+202E through. Nothing
  legitimate needs one, and they would otherwise reach ffmpeg argv, object
  keys, `Content-Disposition` and log lines, where a right-to-left override is
  a filename-spoofing tool.

  Doing it here rather than per type is the point: a source type cannot forget
  it, so a NUL byte never reaches a confinement check.

  ## Canonical identity

  `canonical/1` produces the string `AudioProxy.CacheKey` hashes as the "what"
  half of a variant's identity. Each type renders its own, under one rule this
  module enforces by construction: both encodings of one source parse to the
  same typed source, so they render the same bytes and share a cache key.
  """

  alias AudioProxy.Source.Type

  # Source types, in dispatch order. Each slice that adds one appends here;
  # nothing loads a type at runtime.
  @types [AudioProxy.Source.Local]

  # A `%` that is not the start of a well-formed escape.
  @malformed_escape_re ~r/%(?![0-9A-Fa-f]{2})/

  # Cc = control, Cf = format (bidi overrides, zero-width joiners), Zl/Zp =
  # line and paragraph separators. See the moduledoc for why not `\x00-\x1f`.
  @control_char_re ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  @typedoc """
  A resolved source: a tagged tuple whose first element identifies its type.

  The shape past the tag is the type's own business — `{:local, path}`,
  `{:s3, bucket, key}`, `{:http, url}` — and consumers pattern-match the shape
  their slice documents.
  """
  @type t :: tuple()

  @typedoc """
  Why a source was rejected before any source type saw it.

  A type adds its own reasons on top; these are the ones the shared layer
  produces.
  """
  @type error_reason ::
          :unknown_encoding
          | :invalid_encoding
          | :malformed_escape
          | :empty_source
          | :control_character
          | :unknown_scheme

  @doc """
  Parses a source segment (or its already-split parts) into a typed source.

  Accepts `"plain/s3://b/k"` or `["plain", "s3://b/k"]`; a list is joined with
  `/` before parsing. The input must be the **raw**, still-escaped path bytes —
  the same bytes the signature was computed over. Never pass `conn.path_info`,
  which Plug has already percent-decoded (see
  `AudioProxy.Plugs.VerifySignature`); passing it would decode twice.

  `types` overrides the registered source types, which is how this module is
  tested against a stand-in rather than a real one.

      iex> AudioProxy.Source.parse("plain/local://previews/track.wav")
      {:ok, {:local, "previews/track.wav"}}

      iex> AudioProxy.Source.parse("plain/s3://masters/a.wav")
      {:error, :unknown_scheme}

      iex> AudioProxy.Source.parse("nonsense/x")
      {:error, :unknown_encoding}

  One consequence of decoding exactly once is worth spelling out: a source that
  already carries escapes has to be escaped *again* for the `plain/` form,
  since the outer layer is what gets stripped. A URL ending in `a%20b.wav` is
  written `plain/https://h/a%2520b.wav`. That is precisely the headache `enc/`
  exists to avoid — base64url the source as written and be done.
  """
  @spec parse(String.t() | [String.t()], [module()]) ::
          {:ok, t()} | {:error, error_reason() | atom()}
  def parse(source, types \\ types())

  def parse(source, types) when is_list(source), do: source |> Enum.join("/") |> parse(types)

  def parse(source, types) when is_binary(source) do
    with {:ok, decoded} <- decode(source),
         :ok <- vet(decoded),
         {:ok, type, body} <- dispatch(decoded, types) do
      type.parse(body)
    end
  end

  @doc """
  Renders the canonical identity string for `source`, via its own type.

  This is the second half of the cache-key input (`AudioProxy.CacheKey`), and
  it is what makes the two encodings one variant.
  """
  @spec canonical(t(), [module()]) :: String.t()
  def canonical(source, types \\ types()),
    do: source |> type_for!(types) |> apply(:canonical, [source])

  @doc """
  Decides whether `source` may be served, via its own type.

  See `AudioProxy.Source.Type` for why the policy is the type's and not this
  module's.
  """
  @spec authorize(t(), [module()]) :: :ok | {:error, :not_allowed}
  def authorize(source, types \\ types()),
    do: source |> type_for!(types) |> apply(:authorize, [source])

  @doc """
  Reports size and ETag material for `source`, via its own type.
  """
  @spec stat(t(), [module()]) :: {:ok, Type.stat()} | {:error, atom()}
  def stat(source, types \\ types()), do: source |> type_for!(types) |> apply(:stat, [source])

  @doc """
  Renders what ffmpeg should be given as input for `source`, via its own type.
  """
  @spec ffmpeg_input(t(), [module()]) :: {:ok, String.t()} | {:error, atom()}
  def ffmpeg_input(source, types \\ types()),
    do: source |> type_for!(types) |> apply(:ffmpeg_input, [source])

  @doc """
  The registered source types.

  `parse/2` and friends take an override, so the contract can be exercised
  against a test-only type without registering one.
  """
  @spec types() :: [module()]
  def types, do: @types

  @doc """
  A short human-readable sentence for `reason`, for error bodies and logs.

  Only the shared layer's reasons; a source type explains its own.
  """
  @spec message(error_reason()) :: String.t()
  def message(:unknown_encoding), do: "source must start with \"plain/\" or \"enc/\""
  def message(:invalid_encoding), do: "encoded source is not valid base64url"
  def message(:malformed_escape), do: "source contains a malformed percent-escape"
  def message(:empty_source), do: "source is empty"
  def message(:control_character), do: "source contains a control character"
  def message(:unknown_scheme), do: "source scheme is not one this proxy serves"

  ## Decoding

  defp decode("plain/" <> rest) do
    if Regex.match?(@malformed_escape_re, rest) do
      {:error, :malformed_escape}
    else
      {:ok, URI.decode(rest)}
    end
  end

  defp decode("enc/" <> rest) do
    # Padded and unpadded spellings decode to the same bytes, so both reach
    # the same source and the same cache key; there is nothing to gain by
    # refusing one, unlike a signature (which must not be malleable).
    case Base.url_decode64(rest, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> padded_decode(rest)
    end
  end

  defp decode(_source), do: {:error, :unknown_encoding}

  defp padded_decode(rest) do
    case Base.url_decode64(rest) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_encoding}
    end
  end

  ## Vetting and dispatch

  defp vet(""), do: {:error, :empty_source}

  defp vet(decoded) do
    cond do
      not String.valid?(decoded) -> {:error, :invalid_encoding}
      Regex.match?(@control_char_re, decoded) -> {:error, :control_character}
      true -> :ok
    end
  end

  defp dispatch(decoded, types) do
    with [scheme, body] <- String.split(decoded, "://", parts: 2),
         scheme = String.downcase(scheme),
         type when not is_nil(type) <- Enum.find(types, &(&1.scheme() == scheme)) do
      {:ok, type, body}
    else
      _ -> {:error, :unknown_scheme}
    end
  end

  defp type_for!(source, types) when is_tuple(source) and tuple_size(source) > 0 do
    tag = elem(source, 0)

    Enum.find(types, &(&1.tag() == tag)) ||
      raise ArgumentError, "no source type registered for tag #{inspect(tag)}"
  end
end
