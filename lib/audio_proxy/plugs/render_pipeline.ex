defmodule AudioProxy.Plugs.RenderPipeline do
  @moduledoc """
  The signed render chain (API doc §2): verify, parse, resolve, act.

  Cheapest checks first — signature verification and both parsers are pure
  functions of the request; the action's `stat` is the only I/O and runs last.
  A halted conn short-circuits the rest of the chain, so a 401 never reaches
  option parsing and a 422 never touches the filesystem.

  Mounted by the router for `GET /:sig/*rest`; `/health` stays outside it, so
  an unsigned liveness check never touches signature verification. The action
  is the seam: a 501 placeholder today, the streaming render in
  `add-render-endpoint`. The info endpoint will reuse the three plugs with an
  action of its own.
  """

  use Plug.Builder

  plug AudioProxy.Plugs.VerifySignature
  plug AudioProxy.Plugs.ParseOptions
  plug AudioProxy.Plugs.ResolveSource
  plug AudioProxy.Plugs.RenderAction
end
