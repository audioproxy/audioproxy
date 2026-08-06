defmodule AudioProxy.VariantCache do
  @moduledoc """
  Serving a variant that is already in the store — everything a client can
  observe about a cache HIT.

  `AudioProxy.VariantStore` owns *where* the bytes are; this module owns what
  happens when they turn out to be there. The split is the same one the API
  doc draws: a store is a backend detail, a HIT is a contract.

  ## Two lines, and only two

  `lookup/1` is the HIT check — a `c:AudioProxy.VariantStore.head/1` behind
  the "is there a store at all" question, answering `:miss` for both
  "unconfigured" and "not stored", because the render path does the same thing
  either way. `serve/3` turns an entry into a response.

  `serve/3` can still answer `:miss`: an entry can be evicted between the head
  and the read, and nothing has been sent at that point, so the request falls
  through to a render rather than failing.

  Everything after the response head is committed, and there the only signal
  left is an abnormal close — the same one, for the same reason, as a render
  that fails after its 200 (§5). Two things reach it. A store read that
  *raises* propagates and the adapter tears the connection down. A store read
  that ends *short* would otherwise complete normally, so `write/3` counts the
  bytes and exits when they fall short of the `Content-Length` already
  promised; see the comment there for why a well-formed short body is the
  worse outcome of the two.

  ## Proxy mode declares a length

  A stored variant has a known size, and declaring it is the entire point of
  caching one: `Content-Length` plus `Accept-Ranges: bytes` is what makes
  seeking, resumption and progress reporting work, none of which a chunked
  MISS can offer. Bandit streams a length-delimited body when the
  `content-length` header is set before `Plug.Conn.send_chunked/2`, so the
  bytes still leave as they are read — declared length and progressive
  delivery are not a trade here.

  Range handling is single-range only. A multipart/byteranges response would
  buy nothing a media client asks for, and RFC 9110 §14.2 permits ignoring a
  `Range` header outright, which is what a multi-range or malformed one gets.
  A syntactically valid range that no byte of the variant can satisfy is a
  `416` — the one status this module produces that is not a HIT's body.

  ## The redirect is not the variant

  Redirect mode answers `302` with a short-lived presigned URL and
  `Cache-Control: no-store`. The no-store is load-bearing rather than
  cautious: the redirect's `Location` *is* a credential with an expiry, and a
  cached 302 hands out URLs that have already expired. The immutable
  cache-control belongs to the variant bytes, which the store serves under its
  own headers — the ones the write-back stored, so a followed redirect
  delivers the same `Content-Type` and `Cache-Control` a proxied HIT would
  have sent.

  Backends without `:presign` never take this path. `AudioProxy.Config`
  refuses that combination at boot, so the runtime check here is a belt on top
  of a brace — and a presign that fails despite it proxies instead, because
  the bytes are readable and the client asked for audio, not for a URL.

  ## What the client contract does not depend on

  Not the backend, and not the serve mode. Both modes deliver the same bytes
  under the same `Content-Type`, `Cache-Control` and `ETag`, and both are
  range-capable — proxy mode because this module implements it, redirect mode
  because the store does. What *does* change the observable response is the
  cache state: the same URL is a chunked, non-seekable `200` while it is being
  rendered and a length-declared, range-capable one afterwards. That is stated
  in §5 as a contract clients must not assume their way around.
  """

  import Plug.Conn

  require Logger

  alias AudioProxy.{Config, ErrorJSON, LogHandler, VariantStore}

  @typedoc "What `lookup/1` found, if anything."
  @type hit :: {:ok, VariantStore.entry()} | :miss

  # Only digits: `Integer.parse/1` would accept `+5` and a leading `-`, and a
  # range spec is `1*DIGIT` (RFC 9110 §14.1) or it is not one.
  #
  # Both this match and the `String.to_integer/1` behind it are linear in the
  # header's length, and the header is bounded by Bandit's own maximum field
  # size — so a range spec cannot be made expensive by making it long.
  @digits ~r/^\d+$/

  @doc """
  Reports whether the variant named by `key` is in the store, whole.

  `:miss` covers every reason a request must render: no store configured,
  nothing stored under the key, an entry whose metadata never landed.
  """
  @spec lookup(VariantStore.key()) :: hit()
  def lookup(key) do
    if VariantStore.configured?() do
      case VariantStore.head(key) do
        {:ok, entry} -> {:ok, entry}
        {:error, _not_found} -> :miss
      end
    else
      :miss
    end
  end

  @doc """
  Serves a stored variant, per `AP_SERVE_MODE`.

  `:miss` means the entry disappeared before a byte was sent and the caller
  should render — see the moduledoc. Any returned conn is sent and halted.
  """
  @spec serve(Plug.Conn.t(), VariantStore.key(), VariantStore.entry()) ::
          {:ok, Plug.Conn.t()} | :miss
  def serve(conn, key, entry) do
    conn = assign(conn, :render_status, :hit)

    if redirect?() do
      redirect(conn, key, entry)
    else
      proxy(conn, key, entry)
    end
  end

  defp redirect?,
    do: Config.get(:serve_mode) == :redirect and :presign in VariantStore.capabilities()

  ## Redirect mode

  defp redirect(conn, key, entry) do
    case VariantStore.presign(key, expires_in: Config.get(:presign_ttl)) do
      {:ok, url} ->
        {:ok,
         conn
         |> mark_hit()
         |> put_resp_header("location", url)
         # Never the variant's immutable policy: this response is a pointer
         # with an expiry, not the bytes it points at.
         |> put_resp_header("cache-control", "no-store")
         |> send_resp(302, "")
         |> halt()}

      # Configured for redirect against a backend that could not produce one.
      # The variant is right there, so serve it rather than fail the request;
      # the log line is what tells an operator their serve mode is not working.
      # `reason` comes from a backend whose entire job is producing URLs that
      # carry a live signature, so it is redacted like any other text this
      # application did not build. `AudioProxy.LogHandler` makes that guarantee
      # for the telemetry it consumes; a direct `Logger` call has to ask.
      {:error, reason} ->
        Logger.warning(
          "could not presign variant #{key}, proxying instead: " <>
            LogHandler.redact(inspect(reason))
        )

        proxy(conn, key, entry)
    end
  end

  ## Proxy mode

  defp proxy(conn, key, %{size: size, metadata: metadata}) do
    case requested_range(conn, size) do
      :none ->
        deliver(conn, key, nil, 200, size, metadata)

      {:ok, {first, last} = range} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> deliver(key, range, 206, last - first + 1, metadata)

      :unsatisfiable ->
        {:ok, unsatisfiable(conn, size)}
    end
  end

  defp deliver(conn, key, range, status, length, metadata) do
    case VariantStore.get_stream(key, range) do
      {:ok, stream} ->
        conn =
          conn
          |> mark_hit()
          |> describe(metadata)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-length", Integer.to_string(length))
          |> send_chunked(status)

        {:ok, write(conn, stream, length)}

      # Evicted between the head and the read. Nothing has been sent, so this
      # is still a miss and the caller renders.
      {:error, _gone_or_invalid} ->
        :miss
    end
  end

  # A store read that raises here is past the point of a graceful answer — the
  # status line and the declared length are already on the wire — so it
  # propagates and the adapter tears the connection down, which is §5's signal
  # for a body that will not be completed.
  #
  # A read that ends *short* needs the same treatment and does not get it for
  # free, which is why the bytes are counted. `Content-Length` has been
  # promised; `Local.stream/3` halts rather than raises when the file turns out
  # to be shorter than `head/1` said, so without this the response would end
  # cleanly, well-formed, and a body short of its own declared length. Over a
  # keep-alive connection that is worse than a truncated download: the client
  # waits for bytes that never come and reads the next response as this one's
  # body. Neither Bandit nor Plug reconciles the count, so this does.
  defp write(conn, stream, declared) do
    stream
    |> Enum.reduce_while({conn, 0}, fn data, {conn, written} ->
      case chunk(conn, data) do
        {:ok, conn} ->
          {:cont, {conn, written + byte_size(data)}}

        # Nothing to clean up: no render is running, and the stream's own
        # teardown closes the store handle as the enumeration unwinds. Not a
        # short body either — nobody is left to be misled by one.
        {:error, reason} ->
          Logger.debug("client disconnected mid-hit: #{inspect(reason)}")
          {:halt, {:gone, conn}}
      end
    end)
    |> finish(declared)
  end

  defp finish({:gone, conn}, _declared), do: halt(conn)
  defp finish({conn, declared}, declared), do: halt(conn)

  # The reason is `:shutdown`-tagged and names both counts, so an operator
  # reading the adapter's exit report can tell a store that moved under a read
  # from a bug in this module. Same mechanism, and the same reasoning, as
  # `AudioProxy.Plugs.RenderAction.abort/2`.
  defp finish({_conn, written}, declared) do
    Logger.warning(
      "variant store delivered #{written} of #{declared} declared bytes; tearing down the response"
    )

    exit({:shutdown, {:variant_truncated, declared, written}})
  end

  # The variant's own headers, as the write-back stored them — not rebuilt
  # from the options. That is what makes a proxied HIT and a followed redirect
  # byte-identical in what they claim to be.
  defp describe(conn, metadata) do
    conn
    |> put_resp_content_type(metadata.content_type, nil)
    |> put_resp_header("cache-control", metadata.cache_control)
    |> put_resp_header("etag", metadata.etag)
  end

  # The one place that says "this response is a HIT", so it is also the one
  # place that counts one. Every path that reaches it has committed — the
  # presign came back, the store handed over a stream, or the range was
  # refused against a variant that is demonstrably there — which is what keeps
  # the entry evicted between `head/1` and the read out of the hit count: that
  # request falls through to a render and is counted as a `:miss` by the
  # action instead.
  defp mark_hit(conn) do
    AudioProxy.Telemetry.cache_lookup(%{status: :hit, format: conn.assigns.options.format})

    put_resp_header(conn, "x-audio-proxy", "HIT")
  end

  ## Range

  # RFC 9110 §14.1. Anything this does not understand — another unit, several
  # ranges, a malformed spec — is `:none`, which §14.2 permits and which
  # answers the whole variant.
  defp requested_range(conn, size) do
    case get_req_header(conn, "range") do
      [value] -> parse_range(value, size)
      _absent_or_repeated -> :none
    end
  end

  defp parse_range("bytes=" <> spec, size) do
    case String.split(spec, ",") do
      [single] -> parse_single(String.trim(single), size)
      _multiple -> :none
    end
  end

  defp parse_range(_other_unit, _size), do: :none

  # A suffix range: the last `length` bytes, clamped to the whole variant.
  # `bytes=-0` asks for nothing, which §14.1.2 makes unsatisfiable rather than
  # empty.
  defp parse_single("-" <> suffix, size) do
    if suffix =~ @digits do
      case String.to_integer(suffix) do
        0 -> :unsatisfiable
        length -> satisfiable(max(size - length, 0), size - 1, size)
      end
    else
      :none
    end
  end

  defp parse_single(spec, size) do
    case String.split(spec, "-", parts: 2) do
      [first, ""] ->
        with {:ok, first} <- integer(first), do: satisfiable(first, size - 1, size)

      [first, last] ->
        with {:ok, first} <- integer(first),
             {:ok, last} <- integer(last) do
          # A last-byte-pos below first-byte-pos is not a range at all; §14.1.1
          # calls it invalid, so it is ignored rather than refused.
          if last < first, do: :none, else: satisfiable(first, min(last, size - 1), size)
        end

      _no_hyphen ->
        :none
    end
  end

  defp integer(text) do
    if text =~ @digits, do: {:ok, String.to_integer(text)}, else: :none
  end

  # A first-byte-pos past the end has nothing to answer with — including on a
  # zero-length variant, where `last` is -1 and every range is unsatisfiable.
  defp satisfiable(first, last, size) when first < size and first <= last do
    {:ok, {first, last}}
  end

  defp satisfiable(_first, _last, _size), do: :unsatisfiable

  # The HIT header travels with the 416: the variant *was* found, and an
  # operator reading the log should see the same thing the client did.
  defp unsatisfiable(conn, size) do
    conn
    |> mark_hit()
    |> ErrorJSON.halt_with({:range_not_satisfiable, size})
  end
end
