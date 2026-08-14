defmodule AudioProxy.Plugs.SignedChain do
  @moduledoc """
  The checks every signed request passes before its action (API doc §2):
  verify, parse, check, resolve.

  Cheapest checks first — signature verification, both parsers and the expiry
  check are pure functions of the request (and, for expiry, the clock), and
  authorization is an existence-blind confinement resolution; the action's
  `stat` is the only source-metadata I/O and runs last. A halted conn
  short-circuits the rest of the chain, so a 401 never reaches option parsing,
  a 422 never touches the filesystem, and a 410 never learns whether the source
  it names exists.

  The mounting contract is the assigns chain: `VerifySignature` assigns
  `:rest_of_path`, `ParseOptions` assigns `:options` and `:source_string`,
  `CheckExpiry` reads `:options` and assigns nothing, and `ResolveSource`
  assigns `:source` — each plug reads exactly what its predecessor assigns, so
  a plug mounted without its upstream raises `KeyError`. That is why the four
  are one mountable unit rather than a list each caller repeats.

  **This module exists so there is nowhere to copy it to.** `add-expiring-urls`
  added `AudioProxy.Plugs.CheckExpiry` to three hand-copied lists, and deleting
  it from the production one left the whole suite green — every expiry test
  drove a test pipeline, so the suite asserted the copy and said nothing about
  the deployment. A plug added here reaches the production pipeline and both
  test mountings at once; nothing has to be remembered for it to.

  Mounted with the action behind it: `AudioProxy.Plugs.RenderPipeline` in
  production, `AudioProxy.FakeFfmpeg.Pipeline` and
  `AudioProxy.CountingProbe.Pipeline` in the suite. The action stays out of
  this unit because its options are exactly what those mountings vary. Do not
  add a way to omit a check.
  """

  use Plug.Builder

  plug AudioProxy.Plugs.VerifySignature
  plug AudioProxy.Plugs.ParseOptions
  plug AudioProxy.Plugs.CheckExpiry
  plug AudioProxy.Plugs.ResolveSource
end
