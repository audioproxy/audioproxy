defmodule AudioProxy.VariantStore do
  @moduledoc """
  The contract a variant store backend implements, and the dispatch to the
  configured one.

  A completed render is written back under its cache key so the next request
  for the same variant is served from storage instead of re-rendered. Where
  that storage *is* — a local directory, an S3 bucket — is a backend behind
  this behaviour, selected by the scheme of `AP_VARIANT_STORE`:

      scheme     module                          slice
      file://    AudioProxy.VariantStore.Local   add-variant-store
      s3://      (arrives with add-s3-client)

  The shape deliberately mirrors `AudioProxy.Source.Type`: one module per
  scheme, five callbacks, and a new backend is a registration rather than an
  edit to the render path. Cache behaviour never depends on where source audio
  comes from — a `file://` store caches renders of `s3://` sources and vice
  versa.

  ## The callbacks, in the order a request meets them

    * `c:head/1` — is this variant stored, and what would serving it need to
      know? The HIT check.
    * `c:get_stream/2` — the bytes, or a Range slice of them, as a lazy
      stream. Proxy-mode serving.
    * `c:presign/2` — a URL the client can be redirected to. Redirect-mode
      serving, and only for backends that advertise it (see below).
    * `c:put_stream/3` — the write-back: bytes plus the response metadata
      they must be served with.
    * `c:capabilities/0` — what this backend can do beyond the mandatory four.

  ## Metadata travels with the bytes

  `c:put_stream/3` takes a `t:metadata/0` because a store that keeps only
  bytes cannot serve a redirected fetch correctly: a player handed
  `application/octet-stream` may refuse to decode it. Every backend persists
  the metadata; a backend that cannot attach it to a *direct* fetch (the
  redirect case) simply does not advertise `:presign`, and
  `AudioProxy.Config` refuses `AP_SERVE_MODE=redirect` against it at boot.

  ## Atomic or absent

  A `c:put_stream/3` that does not run to completion — the render failed, the
  write errored — must leave nothing readable under the key. Each backend
  implements that with whatever its storage offers: the local backend stages
  into a temp file inside the store and `File.rename/2`s on completion; the
  S3 backend will use multipart complete/abort. `c:head/1` answering `{:ok,
  _}` therefore always means the whole variant, with its metadata.
  """

  alias AudioProxy.Config

  @typedoc "The cache key a variant is stored under — see `AudioProxy.CacheKey`."
  @type key :: String.t()

  @typedoc """
  The response headers a stored variant must be served with: its content type,
  the immutable cache-control the render endpoint would have sent, and the
  ETag (the quoted cache key). Stored alongside the bytes so a store-direct
  fetch serves correctly without the proxy in the path.
  """
  @type metadata :: %{
          content_type: String.t(),
          cache_control: String.t(),
          etag: String.t()
        }

  @typedoc "What `c:head/1` reports about a stored variant."
  @type entry :: %{size: non_neg_integer(), metadata: metadata()}

  @typedoc """
  An inclusive byte range (`{first, last}`, RFC 9110 §14), or `nil` for the
  whole variant. A `last` past the end is truncated, as Range semantics ask;
  a `first` past the end is `:invalid_range`.
  """
  @type range :: {non_neg_integer(), non_neg_integer()} | nil

  @typedoc """
  What a backend can do beyond the mandatory callbacks.

    * `:presign` — `c:presign/2` produces working URLs, which is what
      redirect serving needs. A backend without it is proxy-mode only.
  """
  @type capability :: :presign

  @typedoc """
  The parsed `AP_VARIANT_STORE` value, as `AudioProxy.Config` holds it.

  `{:module, backend}` is the test seam described at `backend_for/1`, not a
  value any environment can produce.
  """
  @type config :: {:file, Path.t()} | {:module, module()}

  @doc "Reports whether the variant named by `key` is stored, whole, with its metadata."
  @callback head(key()) :: {:ok, entry()} | {:error, :not_found}

  @doc """
  Streams the stored variant's bytes, or the Range slice of them.

  The stream is lazy and bounded-memory: chunks, never the whole variant at
  once.
  """
  @callback get_stream(key(), range()) ::
              {:ok, Enumerable.t()} | {:error, :not_found | :invalid_range}

  @doc """
  Writes a variant: consumes `chunks` (an enumerable of binaries) to
  completion, then commits bytes and metadata under `key` — atomically, so a
  reader sees the whole variant or nothing.

  If `chunks` raises — which is how the write-back tee signals a render that
  failed or was cancelled mid-stream — the write is aborted, anything staged
  is discarded, and the exception comes back as `{:error, exception}`.
  """
  @callback put_stream(key(), Enumerable.t(), metadata()) :: :ok | {:error, term()}

  @doc """
  Produces a URL a client can fetch the stored variant from directly.

  `{:error, :unsupported}` from a backend without the `:presign` capability.
  """
  @callback presign(key(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc "The optional abilities this backend has. See `t:capability/0`."
  @callback capabilities() :: [capability()]

  @doc "Reports whether `AP_VARIANT_STORE` is configured at all."
  @spec configured?() :: boolean()
  def configured?, do: Config.get(:variant_store) != nil

  @doc """
  The backend module for a parsed store value.

  Used by `AudioProxy.Config` to validate the serve mode against the
  backend's capabilities at boot, before anything is stored.
  """
  @spec backend_for(config()) :: module()
  def backend_for({:file, _root}), do: AudioProxy.VariantStore.Local

  # A backend that names itself. `AudioProxy.Config` never produces this shape
  # — `AP_VARIANT_STORE` is a URL, and every scheme maps to a module above — so
  # it is not configuration surface. It is the seam the serving path is tested
  # through: `:presign` is a capability no shipped backend has until the S3
  # one lands, and redirect mode would otherwise ship unexercised.
  def backend_for({:module, module}) when is_atom(module), do: module

  @doc "The configured backend module. Callers must check `configured?/0` first."
  @spec backend() :: module()
  def backend, do: backend_for(Config.get(:variant_store))

  @doc "`c:head/1` on the configured backend."
  @spec head(key()) :: {:ok, entry()} | {:error, :not_found}
  def head(key), do: backend().head(key)

  @doc "`c:get_stream/2` on the configured backend."
  @spec get_stream(key(), range()) ::
          {:ok, Enumerable.t()} | {:error, :not_found | :invalid_range}
  def get_stream(key, range), do: backend().get_stream(key, range)

  @doc "`c:put_stream/3` on the configured backend."
  @spec put_stream(key(), Enumerable.t(), metadata()) :: :ok | {:error, term()}
  def put_stream(key, chunks, metadata), do: backend().put_stream(key, chunks, metadata)

  @doc "`c:presign/2` on the configured backend."
  @spec presign(key(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def presign(key, opts \\ []), do: backend().presign(key, opts)

  @doc "`c:capabilities/0` of the configured backend."
  @spec capabilities() :: [capability()]
  def capabilities, do: backend().capabilities()
end
