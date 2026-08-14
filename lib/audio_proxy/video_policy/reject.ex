defmodule AudioProxy.VideoPolicy.Reject do
  @moduledoc """
  The default policy: a source carrying video is refused.

  This is what the proxy did before `AudioProxy.VideoPolicy` existed and what
  it does with nothing configured — "this proxy does not touch video", with no
  endpoint-shaped exception and no way for an operator of the published image
  to arrange one.
  """

  @behaviour AudioProxy.VideoPolicy

  @impl true
  def verdict(_probe), do: :reject
end
