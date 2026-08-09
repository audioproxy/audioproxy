defmodule AudioProxy.ErrorJSON do
  @moduledoc """
  The §5 error contract as one table: structured error in, response out.

  Plugs and actions never build their own error responses. They return
  `{:error, reason}` values — a bare atom, a `%AudioProxy.OptionError{}`, or a
  `{:queue_full, retry_after}` tuple — and this module renders the
  `{status, headers, body}` triple for it. One table, keyed by error class, so
  the mapping is reviewable against `docs/audio-proxy-api-v1.md` §5 as a whole
  and a producer landing later (429 with the render semaphore) touches nothing
  here — the streaming action, which produces 415/500/504, did not.

  The rows, one per §5 line:

      error                          status  body `error`        extra headers
      :invalid_signature             401     invalid_signature
      source failure (see below)     404     not_found
      :source_too_large              413     source_too_large
      :undecodable_source            415     undecodable_source
      :video_source                  415     video_source
      {:range_not_satisfiable, size} 416     range_not_satisfiable  Content-Range
      %OptionError{}                 422     invalid_options
      {:queue_full, retry_after}     429     queue_full          Retry-After
                                             (queue full, or a wait for a
                                             slot that ran out of budget)
      :render_failed                 500     render_failed
      :probe_failed                  500     probe_failed
      :not_configured                500     not_configured
      :upstream_unavailable          502     upstream_unavailable
      :render_timeout                504     render_timeout
      :probe_timeout                 504     probe_timeout

  The 416 row belongs to the variant cache: only a stored variant has a known
  size and therefore a range that can be refused. A `Range` on anything still
  rendering is ignored, per §5, so this status is unreachable from the render
  path.

  The 500 and 502 rows are this table's additions to §5's, and both are
  deliberate: §5 enumerates what a *client* can have got wrong, and neither a
  failed render nor an unreachable store is that. A render that fails for none
  of §5's reasons — no ffmpeg on `PATH`, a full disk, a diagnostic no
  classifier recognises — still has to answer something, and a
  plausible-looking 4xx would tell the client to stop retrying something that
  might well work next time.

  ## The 502 row is not the 404 row

  `:upstream_unavailable` is what a storage backend reports when it could not
  reach its store at all — a transport failure, or a 5xx from S3. It is the
  one source-side failure that is *not* the blind 404 below, and the
  distinction is the whole point: an outage says nothing about whether the
  object exists, so answering 404 reports a deletion that did not happen and
  then edge-caches that report for ten seconds, suppressing the retry that
  would have worked. 502 says the three things that are true — not the
  client's fault, the resource may well exist, retrying is reasonable — and
  carries `no-store` with the rest of the transient rows.

  `:not_configured` sits beside it at 500 for the same honesty: a backend with
  no credentials is an operator fault no client action can resolve, and it is
  neither a failed render nor a failed probe, so it does not borrow their
  bodies and send an operator to the wrong variable.

  `render/1` is the pure mapping — that is what the per-row unit tests pin —
  and `halt_with/2` sends it and halts, which is all a plug ever calls.

  ## Every error declares its cacheability

  `halt_with/2` also sets a `Cache-Control` derived from the status, replacing
  a framework default with a stated policy.

  The default it replaces is `Plug.Conn`'s: a response that sets no
  `cache-control` still sends `max-age=0, private, must-revalidate`. So this
  is not filling a silence — it is a deliberate *relaxation*, dropping
  `private` so the edge may share an error and trading `max-age=0` for a short
  per-class TTL so a repeated failure costs the origin once rather than every
  time. Sound here because an error body is a pure function of the URL: no
  cookies, no auth headers, nothing per-user to leak into a shared cache.

      404, 413, 415   max-age=10   verdicts about the current source bytes;
                                   a re-upload changes them, and 10 s is the
                                   window a just-uploaded source waits
      401, 422        max-age=60   pure functions of the URL — a bad
                                   signature never becomes good, invalid
                                   options never become valid; only a deploy
                                   changes that, and 60 s bounds the window
      416             no-store     the only response here whose body depends
                                   on a request *header*; a shared cache
                                   without `Vary: Range` would hand it to a
                                   client that asked for a range the variant
                                   can satisfy
      429, 5xx        no-store     transient; caching a transient failure
                                   amplifies it

  It lives here and not in `render/1`'s row headers so the pure mapping keeps
  pinning what is *specific* to each row; cacheability is a property of the
  status class, and one derivation cannot drift row by row.

  `class/1` reads the same table for its label rather than its response:
  `halt_with/2` assigns the result to `:error_class`, which is how the
  request log line names what went wrong (`AudioProxy.LogHandler`). Deriving
  it here rather than in the handler is what keeps the log and the response
  body saying the same word — the body's `error` field *is* the class.

  ## The 404 row is deliberately blind

  Every source failure is the same 404, byte for byte: an unauthorized source,
  a missing file, an unparseable encoding, an unknown scheme. §5 has no 403,
  and a distinguishable response would turn the source policy into an
  existence oracle for whatever sits behind it.

  A source type added later must extend `@source_not_found` — exposed as
  `not_found_reasons/0`, so tests exercise the module's own list rather than
  a copy that can drift — with its own "not there" reasons, as part of its
  slice. An unlisted reason does not become a wrong response: `render/1` has
  no clause for it and raises `FunctionClauseError`, so the mistake crashes
  that slice's end-to-end tests instead of answering a plausible status in
  production. There is deliberately no catch-all: an unlisted reason is a
  programmer error, and a default row would hide it.
  """

  import Plug.Conn

  alias AudioProxy.OptionError

  @typedoc """
  What plugs and actions hand to `render/1`.

  Bare atoms for the data-less rows, `%AudioProxy.OptionError{}` for 422, and
  `{:queue_full, retry_after_seconds}` for 429 — the shape the render
  semaphore slice will produce, carrying the queue's own estimate so this
  module never invents a `Retry-After` value.
  """
  @type structured ::
          OptionError.t()
          | atom()
          | {:queue_full, non_neg_integer()}
          | {:range_not_satisfiable, non_neg_integer()}

  # Reasons that all mean "no servable source": the shared resolver's
  # rejections (`AudioProxy.Source`), each source type's own, and the storage
  # seam's verdicts (`authorize/1`, `stat/1`, `ffmpeg_input/1`).
  #
  # `:no_backend` is the one worth a word. A remote source whose backend has
  # not shipped yet is, from a client's side of the wire, exactly "not one this
  # proxy may serve" — §5's own words for the 404 row — so it answers the same
  # blind 404 as everything else here rather than a 5xx blaming the operator
  # for a URL that names nothing servable.
  @source_not_found [
    :unknown_encoding,
    :invalid_encoding,
    :malformed_escape,
    :empty_source,
    :control_character,
    :unknown_scheme,
    :empty_path,
    :missing_bucket,
    :missing_key,
    :invalid_url,
    :userinfo_not_allowed,
    :source_too_long,
    :no_backend,
    :not_allowed,
    :not_found
  ]

  @doc """
  The error reasons that render as the generic, byte-identical 404.

  Public so tests and future source types exercise this module's own list —
  a hand-copied list elsewhere would drift silently. Extend it, in the same
  change, whenever a source type gains a new "not there" reason.
  """
  @spec not_found_reasons() :: [atom()]
  def not_found_reasons, do: @source_not_found

  # One representative error per row of the moduledoc table — the input a
  # caller would hand `render/1` to produce that row. It exists so `rows/0`
  # can *derive* the table rather than restate it. The 404 row takes the first
  # source reason, since every one of them renders byte-identically.
  #
  # It has to grow with `render/1`, and neither direction is self-enforcing.
  # A row here without a clause below crashes `rows/0` loudly. A clause below
  # without a row here does *not* — `rows/0` would simply omit it, and the
  # llms.txt drift guard would then compare the document against an
  # incomplete set and pass. `AudioProxy.ErrorJSONTest` closes that direction
  # by counting the clauses; without it "the docs cannot drift" would be true
  # only of the errors somebody remembered to list.
  @representative_errors [
    :invalid_signature,
    hd(@source_not_found),
    :source_too_large,
    :undecodable_source,
    :video_source,
    {:range_not_satisfiable, 0},
    %OptionError{segment: "f:xyz", reason: :invalid_value},
    {:queue_full, 1},
    :render_failed,
    :probe_failed,
    :not_configured,
    :upstream_unavailable,
    :render_timeout,
    :probe_timeout
  ]

  @doc """
  The error contract as data: one `{status, error}` pair per row of the table.

  Public for the same reason `not_found_reasons/0` is — so a check of what the
  documentation claims runs against this module's own mapping rather than a
  copy of it. `AudioProxy.LlmsDocsTest` compares it with the error table in
  `llms-full.txt`, both directions.
  """
  @spec rows() :: [{pos_integer(), String.t()}]
  def rows do
    Enum.map(@representative_errors, fn error ->
      {status, _headers, body} = render(error)
      {status, JSON.decode!(body)["error"]}
    end)
  end

  @doc """
  Maps a structured error to its `{status, headers, body}` triple.

  `headers` covers the rows that carry more than a body — today only 429's
  `Retry-After`. `body` is the encoded JSON, so tests can pin it byte for
  byte.
  """
  @spec render(structured()) ::
          {status :: pos_integer(), headers :: [{String.t(), String.t()}], body :: String.t()}
  # `Content-Range: bytes */size` is what tells the client the size it should
  # have asked within — RFC 9110 §14.4 requires it on a 416.
  def render({:range_not_satisfiable, size}) when is_integer(size) and size >= 0 do
    body = encode(%{error: "range_not_satisfiable", message: "Range not satisfiable"})
    {416, [{"content-range", "bytes */#{size}"}], body}
  end

  def render(%OptionError{} = error) do
    {422, [], encode(%{error: "invalid_options", message: OptionError.message(error)})}
  end

  def render(:invalid_signature) do
    {401, [], encode(%{error: "invalid_signature", message: "Invalid or missing signature"})}
  end

  def render(reason) when reason in @source_not_found do
    {404, [], encode(%{error: "not_found", message: "Source not found"})}
  end

  def render(:source_too_large) do
    {413, [], encode(%{error: "source_too_large", message: "Source exceeds AP_MAX_SRC_BYTES"})}
  end

  def render(:undecodable_source) do
    {415, [], encode(%{error: "undecodable_source", message: "Source format is not decodable"})}
  end

  # Its own row rather than a second message on `:undecodable_source`: the
  # source decodes perfectly well, and a client told "not decodable" about a
  # file every player opens would go looking for a corrupt upload. This is a
  # policy refusal, and the body says so.
  def render(:video_source) do
    {415, [],
     encode(%{
       error: "video_source",
       message: "Source contains video; this proxy serves audio only"
     })}
  end

  def render({:queue_full, retry_after})
      when is_integer(retry_after) and retry_after >= 0 do
    body = encode(%{error: "queue_full", message: "Render queue is full"})
    {429, [{"retry-after", Integer.to_string(retry_after)}], body}
  end

  def render(:render_failed) do
    {500, [], encode(%{error: "render_failed", message: "Render failed"})}
  end

  def render(:render_timeout) do
    {504, [], encode(%{error: "render_timeout", message: "Render exceeded AP_RENDER_TIMEOUT"})}
  end

  # The probe pair. Separate rows rather than reusing the render ones because
  # the body names the limit an operator would raise, and `AP_RENDER_TIMEOUT`
  # is not that limit for `/info` — the two budgets are configured apart, and
  # an error that named the wrong one would send them to the wrong variable.
  def render(:probe_failed) do
    {500, [], encode(%{error: "probe_failed", message: "Probe failed"})}
  end

  def render(:probe_timeout) do
    {504, [], encode(%{error: "probe_timeout", message: "Probe exceeded AP_PROBE_TIMEOUT"})}
  end

  # The storage seam's own two rows. Neither is a source failure, so neither
  # is the blind 404 — see the moduledoc.
  def render(:not_configured) do
    body = encode(%{error: "not_configured", message: "Storage backend is not configured"})
    {500, [], body}
  end

  def render(:upstream_unavailable) do
    body = encode(%{error: "upstream_unavailable", message: "Storage backend is unavailable"})
    {502, [], body}
  end

  @doc """
  Names the error class — the same word the response body's `error` field
  carries.

  One clause per row, and no catch-all, for the reason the moduledoc gives:
  an unlisted reason should crash its own slice's tests rather than get a
  plausible label in production.
  """
  @spec class(structured()) :: atom()
  def class(%OptionError{}), do: :invalid_options
  def class(reason) when reason in @source_not_found, do: :not_found
  def class({:queue_full, _retry_after}), do: :queue_full
  def class({:range_not_satisfiable, _size}), do: :range_not_satisfiable
  def class(:invalid_signature), do: :invalid_signature
  def class(:source_too_large), do: :source_too_large
  def class(:undecodable_source), do: :undecodable_source
  def class(:video_source), do: :video_source
  def class(:render_failed), do: :render_failed
  def class(:render_timeout), do: :render_timeout
  def class(:probe_failed), do: :probe_failed
  def class(:probe_timeout), do: :probe_timeout
  def class(:not_configured), do: :not_configured
  def class(:upstream_unavailable), do: :upstream_unavailable

  @doc """
  Sends the rendered error and halts the conn — the only call a plug needs.
  """
  @spec halt_with(Plug.Conn.t(), structured()) :: Plug.Conn.t()
  def halt_with(conn, error) do
    {status, headers, body} = render(error)

    conn
    |> assign(:error_class, class(error))
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", cache_control(status))
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
    end)
    |> send_resp(status, body)
    |> halt()
  end

  @doc """
  The `Cache-Control` an error status carries — see the moduledoc table.

  Public for the same reason `not_found_reasons/0` is: tests and the router's
  own unmatched-route 404 read this derivation rather than a copy of it.
  """
  @spec cache_control(pos_integer()) :: String.t()
  def cache_control(status) when status in [404, 413, 415], do: "max-age=10"
  def cache_control(status) when status in [401, 422], do: "max-age=60"
  def cache_control(status) when status in [416, 429] or status >= 500, do: "no-store"

  defp encode(map), do: JSON.encode!(map)
end
