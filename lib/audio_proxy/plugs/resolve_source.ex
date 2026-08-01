defmodule AudioProxy.Plugs.ResolveSource do
  @moduledoc """
  Parses the source half of the path into a typed source and authorizes it
  (API doc §1, §5).

  Two checks: `AudioProxy.Source.parse/1` decodes and vets the source string
  (pure), and `AudioProxy.Source.authorize/1` asks the source's own type
  whether it may be served. Authorization is a *policy* verdict, but not
  I/O-free: for `local://` sources it resolves confinement on the filesystem —
  root resolution plus a symlink hop per path component, existence-blind — so
  it costs a handful of `read_link` calls per request. It never reads the
  source's content or metadata. On success the typed source lands in
  `assigns.source`.

  Every failure halts with the same generic 404 from `AudioProxy.ErrorJSON` —
  the no-oracle rule: an unauthorized source, an unparseable one, and one that
  does not exist are indistinguishable on the wire.

  Source-metadata I/O deliberately does not happen here. `stat/1` runs in the
  action, because the info endpoint shares these plugs and wants to stat only
  after deciding what it serves (conditional requests short-circuit it);
  keeping that read out of the plugs preserves the reuse.
  """

  @behaviour Plug

  import Plug.Conn

  alias AudioProxy.{ErrorJSON, Source}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, source} <- Source.parse(conn.assigns.source_string),
         :ok <- Source.authorize(source) do
      assign(conn, :source, source)
    else
      {:error, reason} -> ErrorJSON.halt_with(conn, reason)
    end
  end
end
