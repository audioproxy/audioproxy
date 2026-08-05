defmodule AudioProxy.Plugs.Action do
  @moduledoc """
  Picks the action at the end of the signed chain: render, or info.

  Dispatch cannot happen in the router. `/{sig}/info/{source}` and
  `/{sig}/f:mp3/{source}` are the same route — a signature, then a rest — and
  which endpoint was asked for is only knowable once the signature has been
  verified and the rest split into its options half. That is
  `AudioProxy.Plugs.ParseOptions`' job, and it says so by assigning `:action`.
  This plug reads it, and nothing else does.

  Keeping it a separate plug rather than a clause inside either action is what
  keeps both actions ignorant of the other. Each has its own options, passed
  through under its own key, so a test mounting a stand-in binary names which
  one it is standing in for:

      plug AudioProxy.Plugs.Action, render: [executable: "…/fake_ffmpeg.sh"]
      plug AudioProxy.Plugs.Action, info: [executable: "…/fake_ffprobe.sh"]
  """

  @behaviour Plug

  alias AudioProxy.Plugs.{InfoAction, RenderAction}

  @typedoc """
  Plug options: per-action option lists, each forwarded verbatim to that
  action's `init/1`.
  """
  @type opts :: [render: keyword(), info: keyword()]

  @impl true
  def init(opts) do
    %{
      render: RenderAction.init(Keyword.get(opts, :render, [])),
      info: InfoAction.init(Keyword.get(opts, :info, []))
    }
  end

  @impl true
  def call(%Plug.Conn{assigns: %{action: :info}} = conn, opts) do
    InfoAction.call(conn, opts.info)
  end

  def call(conn, opts), do: RenderAction.call(conn, opts.render)
end
