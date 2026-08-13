defmodule AudioProxy.Plugs.CheckExpiry do
  @moduledoc """
  Refuses a request that has outlived its `exp` (API doc §3, §5).

  One check, and its position in the chain is the design. It runs *after*
  `AudioProxy.Plugs.VerifySignature`, because `exp` is only worth anything
  under the signature — an unsigned timestamp is a suggestion — and *before*
  `AudioProxy.Plugs.ResolveSource`, so an expired URL touches no storage, spawns
  no subprocess and reveals nothing about whether the source it names exists.
  An expired URL is answered from the URL alone.

  `AudioProxy.Expiry` owns the verdict; this plug owns only where it is asked.

  ## `/info` has no options to carry it

  `GET /{sig}/info/{source}` (§2) has no options segment, so `exp` cannot ride
  it without a grammar change — `AudioProxy.Plugs.ParseOptions` deliberately
  assigns no `:options` for an info request. This plug passes such a conn
  through untouched rather than materializing a default struct to ask a
  question whose answer is fixed. Extending the grammar is its own change if
  demand appears; info URLs are operator-to-operator.
  """

  @behaviour Plug

  alias AudioProxy.{ErrorJSON, Expiry}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{options: options}} = conn, _opts) do
    case Expiry.check(options) do
      :ok -> conn
      {:error, reason} -> ErrorJSON.halt_with(conn, reason)
    end
  end

  def call(conn, _opts), do: conn
end
