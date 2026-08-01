defmodule AudioProxy.ErrorJSON do
  @moduledoc """
  The §5 error contract as one table: structured error in, response out.

  Plugs and actions never build their own error responses. They return
  `{:error, reason}` values — a bare atom, a `%AudioProxy.OptionError{}`, or a
  `{:queue_full, retry_after}` tuple — and this module renders the
  `{status, headers, body}` triple for it. One table, keyed by error class, so
  the mapping is reviewable against `docs/audio-proxy-api-v1.md` §5 as a whole
  and a producer landing later (415/504 with the streaming action, 429 with
  the render semaphore) touches nothing here.

  The rows, one per §5 line:

      error                          status  body `error`        extra headers
      :invalid_signature             401     invalid_signature
      source failure (see below)     404     not_found
      :source_too_large              413     source_too_large
      :undecodable_source            415     undecodable_source
      %OptionError{}                 422     invalid_options
      {:queue_full, retry_after}     429     queue_full          Retry-After
      :render_timeout                504     render_timeout

  `render/1` is the pure mapping — that is what the per-row unit tests pin —
  and `halt_with/2` sends it and halts, which is all a plug ever calls.

  ## The 404 row is deliberately blind

  Every source failure is the same 404, byte for byte: an unauthorized source,
  a missing file, an unparseable encoding, an unknown scheme. §5 has no 403,
  and a distinguishable response would turn the source policy into an
  existence oracle for whatever sits behind it. A source type added later must
  extend `@source_not_found` with its own "not there" reasons as part of its
  slice — anything it returns that is not listed here (or another row's shape)
  fails to render loudly, in tests, rather than silently becoming a 500.
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
  @type structured :: OptionError.t() | atom() | {:queue_full, non_neg_integer()}

  # Reasons that all mean "no servable source": the shared resolver's
  # rejections (`AudioProxy.Source`), the local type's own, and the storage
  # seam's verdicts (`authorize/1`, `stat/1`, `ffmpeg_input/1`).
  @source_not_found [
    :unknown_encoding,
    :invalid_encoding,
    :malformed_escape,
    :empty_source,
    :control_character,
    :unknown_scheme,
    :empty_path,
    :not_allowed,
    :not_found
  ]

  @doc """
  Maps a structured error to its `{status, headers, body}` triple.

  `headers` covers the rows that carry more than a body — today only 429's
  `Retry-After`. `body` is the encoded JSON, so tests can pin it byte for
  byte.
  """
  @spec render(structured()) ::
          {status :: pos_integer(), headers :: [{String.t(), String.t()}], body :: String.t()}
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

  def render({:queue_full, retry_after})
      when is_integer(retry_after) and retry_after >= 0 do
    body = encode(%{error: "queue_full", message: "Render queue is full"})
    {429, [{"retry-after", Integer.to_string(retry_after)}], body}
  end

  def render(:render_timeout) do
    {504, [], encode(%{error: "render_timeout", message: "Render exceeded AP_RENDER_TIMEOUT"})}
  end

  @doc """
  Sends the rendered error and halts the conn — the only call a plug needs.
  """
  @spec halt_with(Plug.Conn.t(), structured()) :: Plug.Conn.t()
  def halt_with(conn, error) do
    {status, headers, body} = render(error)

    conn
    |> put_resp_content_type("application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
    end)
    |> send_resp(status, body)
    |> halt()
  end

  defp encode(map), do: JSON.encode!(map)
end
