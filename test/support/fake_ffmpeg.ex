defmodule AudioProxy.FakeFfmpeg do
  @moduledoc """
  The signed render chain, mounted against `test/support/fake_ffmpeg.sh`
  instead of the real encoder.

  `AudioProxy.Plugs.RenderAction` takes the executable as a plug option
  precisely so this exists: the HTTP lifecycle — headers, chunk cadence,
  disconnect, failure after 200 — is a property of the action and the adapter,
  not of ffmpeg, and driving it with the real binary would mean tests that are
  slow, that need a binary this repo does not ship, and that cannot produce a
  hang or a mid-stream failure on demand.

  Which of those the stand-in performs is chosen by the source filename; see
  the script's header for the list. `AudioProxy.FakeFfmpeg.Router` is a
  stand-in for `AudioProxy.Router` carrying the same route, so a test drives it
  over a real socket exactly as it would the production one.
  """

  @doc "Absolute path to the stand-in encoder."
  @spec path() :: String.t()
  def path, do: Path.expand("fake_ffmpeg.sh", __DIR__)
end

defmodule AudioProxy.FakeFfmpeg.Pipeline do
  @moduledoc "`AudioProxy.Plugs.RenderPipeline` with the stand-in encoder."

  use Plug.Builder

  plug AudioProxy.Plugs.VerifySignature
  plug AudioProxy.Plugs.ParseOptions
  plug AudioProxy.Plugs.ResolveSource
  # Resolved at compile time, which is the same filesystem the tests run on.
  plug AudioProxy.Plugs.RenderAction, executable: AudioProxy.FakeFfmpeg.path()
end

defmodule AudioProxy.FakeFfmpeg.Router do
  @moduledoc "`AudioProxy.Router`'s render route, over the stand-in pipeline."

  use Plug.Router

  alias AudioProxy.FakeFfmpeg.Pipeline

  @pipeline Pipeline.init([])

  # Mirrors `AudioProxy.Router`'s own pre-dispatch work, so the log a test
  # captures here is the log production emits.
  plug Plug.RequestId
  plug :match
  plug :dispatch

  get "/:sig/*rest" do
    conn
    |> assign(:endpoint_class, :render)
    |> Pipeline.call(@pipeline)
  end

  head "/:sig/*rest" do
    conn
    |> assign(:endpoint_class, :render)
    |> Pipeline.call(@pipeline)
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
