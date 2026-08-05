defmodule AudioProxy.Plugs.RenderPipeline do
  @moduledoc """
  The signed chain (API doc §2): verify, parse, resolve, act.

  Cheapest checks first — signature verification and both parsers are pure
  functions of the request, and authorization is an existence-blind
  confinement resolution; the action's `stat` is the only source-metadata
  I/O and runs last. A halted conn short-circuits the rest of the chain, so
  a 401 never reaches option parsing and a 422 never touches the filesystem.

  The mounting contract is the assigns chain: `VerifySignature` assigns
  `:rest_of_path`, `ParseOptions` assigns `:options` and `:source_string`,
  `ResolveSource` assigns `:source`, and each plug reads exactly what its
  predecessor assigns — a plug mounted without its upstream raises
  `KeyError`. Mount the four together, in this order.

  Mounted by the router for `GET /:sig/*rest`; `/health` stays outside it, so
  an unsigned liveness check never touches signature verification.

  The action is the seam, and there are two behind it: the streaming render and
  the info probe. Both endpoints in §2 are the same route and the same first
  three checks, so which one a request reached is a fact the chain discovers
  rather than the router — `AudioProxy.Plugs.ParseOptions` decides it and
  `AudioProxy.Plugs.Action` acts on it.
  """

  use Plug.Builder

  plug AudioProxy.Plugs.VerifySignature
  plug AudioProxy.Plugs.ParseOptions
  plug AudioProxy.Plugs.ResolveSource
  plug AudioProxy.Plugs.Action
end
