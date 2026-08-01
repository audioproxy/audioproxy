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

  Expects `AudioProxy.Plugs.VerifySignature` to have run: `rest_of_path` must
  be the verified raw path bytes, never `conn.path_info` — the source parser
  decodes exactly once, and handing it pre-decoded segments would decode
  twice.
  """

  @behaviour Plug

  import Plug.Conn

  alias AudioProxy.{ErrorJSON, Options}

  @source_markers ~w(plain enc)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, option_segments, source_string} <- split(conn.assigns.rest_of_path),
         {:ok, options} <- Options.parse(option_segments) do
      conn
      |> assign(:options, options)
      |> assign(:source_string, source_string)
    else
      {:error, error} -> ErrorJSON.halt_with(conn, error)
    end
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
