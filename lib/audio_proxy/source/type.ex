defmodule AudioProxy.Source.Type do
  @moduledoc """
  The contract a source type implements (API doc §1).

  `AudioProxy.Source` owns everything the *encodings* imply — `plain/` versus
  `enc/`, decoding exactly once, the rejections no source should survive — and
  nothing else. What a source **is** lives here: one module per scheme,
  registered in the resolver's dispatch table.

      scheme      module                          slice
      local://    AudioProxy.Source.Local         add-local-files-source
      s3://       AudioProxy.Source.S3            add-remote-files-source
      https://    AudioProxy.Source.Https         add-remote-files-source

  Five callbacks, in the order the request path uses them:

    * `c:parse/1` — the decoded body (everything after `scheme://`) into a
      typed source, or a structured error.
    * `c:canonical/1` — that source's identity string, which
      `AudioProxy.CacheKey` hashes.
    * `c:authorize/1` — may this source be served at all?
    * `c:stat/1` and `c:ffmpeg_input/1` — the storage seam: what the render and
      info flows need from a source, and the only two things they need.

  ## Why authorization is a callback

  "Permitted" means a host allowlist for HTTPS, a bucket allowlist for S3, and
  confinement under a configured root for local files. A shared implementation
  would have to know all three, so there isn't one. `AudioProxy.Source`
  guarantees only that every type has an answer — not what answering means.

  ## Why the seam is declared here

  `c:stat/1` and `c:ffmpeg_input/1` are exactly what `add-render-endpoint` and
  `add-info-endpoint` established needing from a source: size and ETag material
  to answer 404/413 before a subprocess starts, and something to hand ffmpeg as
  its input. Declaring them alongside the rest of the contract is what lets a
  new backend be a registration rather than an edit to those flows.

  A type is a plain module, and the registry is a compile-time list — nothing
  loads a source type from configuration.
  """

  alias AudioProxy.Source

  @typedoc """
  What `c:stat/1` reports about a source.

  `size` is `nil` when the backing store genuinely does not know it — an
  origin that answers a HEAD without `Content-Length`, say. That is not an
  error: the render byte cap (`AP_MAX_VARIANT_BYTES`) still bounds what such a
  source can cost, one render's retained output at a time, and refusing
  outright would make the proxy less capable than the ffmpeg it drives. What
  goes unenforced is only `AP_MAX_SRC_BYTES` itself, which needs a size to
  compare against.

  `etag` is whatever that store can offer as a version marker — an S3 ETag, a
  size-and-mtime hash for a local file — and feeds conditional requests on
  `/info`.
  """
  @type stat :: %{size: non_neg_integer() | nil, etag: String.t() | nil}

  @doc """
  The URL scheme this type answers to, lowercase and without `://`.

  Dispatch is case-insensitive, so return the canonical spelling.
  """
  @callback scheme() :: String.t()

  @doc """
  The tag this type's sources carry as their first tuple element.

  Sources are tagged tuples (`{:local, path}`, `{:s3, bucket, key}`), so this
  is how `AudioProxy.Source` routes a source it is handed back to the type
  that produced it.
  """
  @callback tag() :: atom()

  @doc """
  Parses the decoded body — everything after `scheme://` — into a typed source.

  The body has already been percent-decoded (exactly once) or base64url-decoded,
  checked for valid UTF-8, and cleared of control-class code points. It has not
  been interpreted in any other way.
  """
  @callback parse(body :: String.t()) :: {:ok, Source.t()} | {:error, atom()}

  @doc """
  Renders `source`'s canonical identity string.

  Must be a pure function of the typed source, so that two encodings of one
  source yield byte-identical output — that is what makes them one cache key.
  Deployment configuration (a filesystem root, an endpoint override) must not
  appear in it, or variants would not survive a redeployment.
  """
  @callback canonical(source :: Source.t()) :: String.t()

  @doc """
  Decides whether `source` may be served.

  Must return a verdict for any source of this type, including one a caller
  built by hand — a security gate that raises is a security gate that can be
  turned into a 500. Failures are `{:error, :not_allowed}`, which the HTTP
  layer renders as 404; API doc §5 has no 403, and a distinct status would
  turn the policy into an existence oracle.
  """
  @callback authorize(source :: Source.t()) :: :ok | {:error, :not_allowed}

  @doc """
  Reports size and ETag material for `source`, or that it is not there.

  Unlike the rest of this contract, an implementation may do I/O.
  """
  @callback stat(source :: Source.t()) :: {:ok, stat()} | {:error, atom()}

  @doc """
  Renders what ffmpeg should be given as its input for `source`.

  A filesystem path for a local source, a presigned or plain URL for a remote
  one. Always a single argv element — never a shell string.
  """
  @callback ffmpeg_input(source :: Source.t()) :: {:ok, String.t()} | {:error, atom()}
end
