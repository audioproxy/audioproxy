defmodule AudioProxy.Plugs.ParseOptions do
  @moduledoc """
  Splits the verified rest-of-path into its options half and source half, and
  parses the options (API doc §1, §3).

  The source half begins at the first `plain` or `enc` segment — the two
  source encodings `AudioProxy.Source` knows, mirrored here because the
  options grammar cannot delimit itself: a bare segment like `plain` is not a
  valid `key:value` option, so it marks where options end. An option *value*
  can never collide (segments are matched whole, and every option segment
  carries a `:`), and a marker later in the source is safe because only the
  first one splits.

  On success the parsed `%AudioProxy.Options{}` lands in `assigns.options` and
  the source half — raw, still percent-escaped, exactly the bytes the
  signature covered — in `assigns.source_string` for
  `AudioProxy.Plugs.ResolveSource`. On failure the plug halts through
  `AudioProxy.ErrorJSON`: an options error as the 422 naming its segment, and
  a path with no source marker as the generic 404 (nothing servable is named).

  ## `info`, the one segment that is not an option

  `GET /{sig}/info/{source}` (§2) puts a bare `info` where the options go, and
  it is not an option: it names a different endpoint over the same source. So
  it is recognized here, before the options grammar sees it, and it is
  **exclusive** — §2 gives the info endpoint no processing options, and the
  rule is one line rather than a per-option exception list: `info` alone is an
  info request, `info` with anything else is a 422 naming the segment it
  cannot be combined with.

  An info request assigns `:action` as `:info` and deliberately assigns **no**
  `:options` — there is no variant being described, and a materialized default
  `%Options{}` would put an `opts=f:mp3` on the log line of a request that
  asked for no such thing. `AudioProxy.Plugs.Action` reads `:action` to pick
  the action; every other request leaves it `:render`.

  Bare `info` is unambiguous as a marker for the same reason `plain` and `enc`
  are: every real option segment carries a `:`, so no option value can spell
  it, and only the options half is scanned.

  Expects `AudioProxy.Plugs.VerifySignature` to have run: `rest_of_path` must
  be the verified raw path bytes, never `conn.path_info` — the source parser
  decodes exactly once, and handing it pre-decoded segments would decode
  twice.
  """

  @behaviour Plug

  import Plug.Conn

  alias AudioProxy.{ErrorJSON, OptionError, Options}

  @source_markers ~w(plain enc)

  @info "info"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case split(conn.assigns.rest_of_path) do
      {:ok, option_segments, source_string} ->
        conn
        |> assign(:source_string, source_string)
        |> parse(option_segments)

      {:error, error} ->
        ErrorJSON.halt_with(conn, error)
    end
  end

  defp parse(conn, [@info]) do
    conn
    |> assign(:action, :info)
    # The router assigned `:render` before the signature was even checked; from
    # here the log line names the endpoint the request actually reached.
    |> assign(:endpoint_class, :info)
  end

  defp parse(conn, segments) do
    case info_conflict(segments) do
      nil ->
        case Options.parse(segments) do
          {:ok, options} -> assign(conn, :options, options)
          {:error, error} -> ErrorJSON.halt_with(conn, error)
        end

      segment ->
        ErrorJSON.halt_with(conn, OptionError.new(segment, :info_takes_no_options))
    end
  end

  # The offending segment is the *other* one — the thing that cannot be there —
  # so the message names what to remove rather than restating the endpoint.
  defp info_conflict(segments) do
    if @info in segments, do: Enum.find(segments, &(&1 != @info))
  end

  # "/f:opus/br:96/plain/s3://b/k.wav" → {["f:opus", "br:96"], "plain/s3://b/k.wav"}.
  # The leading empty segment is the leading slash, not an empty option; any
  # *further* empty segment is a real one and fails as a 422 in Options. With
  # no marker the path names no source, so it is the same 404 as a missing one.
  defp split(rest_of_path) do
    segments =
      case String.split(rest_of_path, "/") do
        ["" | rest] -> rest
        rest -> rest
      end

    case Enum.find_index(segments, &(&1 in @source_markers)) do
      nil ->
        {:error, :not_found}

      index ->
        options = Enum.take(segments, index)
        source = segments |> Enum.drop(index) |> Enum.join("/")
        {:ok, options, source}
    end
  end
end
