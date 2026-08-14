defmodule AudioProxy.Plugs.RenderPipeline do
  @moduledoc """
  The deployed signed chain: `AudioProxy.Plugs.SignedChain` and then the action.

  The checks ahead of the action, their order and the assigns contract between
  them live in `AudioProxy.Plugs.SignedChain`, which the test pipelines mount
  too — this module is that unit plus the production action options, and the
  test mountings differ from it only in theirs.

  **A new check goes in `SignedChain`, never here.** A plug added between the
  two below runs in production and in neither test mounting, which is the
  divergence the extraction removed, reinstated in one line. Nothing prevents
  it structurally: the seam is "everything ahead of the action", and moving it
  would mean making the action mountable through the unit.

  Mounted by the router for `GET /:sig/*rest`; `/health` stays outside it, so
  an unsigned liveness check never touches signature verification.

  The action is the seam, and there are two behind it: the streaming render and
  the info probe. Both endpoints in §2 are the same route and the same checks,
  so which one a request reached is a fact the chain discovers rather than the
  router — `AudioProxy.Plugs.ParseOptions` decides it and
  `AudioProxy.Plugs.Action` acts on it.
  """

  use Plug.Builder

  plug AudioProxy.Plugs.SignedChain
  plug AudioProxy.Plugs.Action
end
