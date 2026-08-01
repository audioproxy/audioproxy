defmodule AudioProxy.FakeSourceType do
  @moduledoc """
  A source type that exists only so the contract can be tested.

  `AudioProxy.Source` ships no source types — `local://` and the remote forms
  arrive in their own slices — so without a stand-in there would be nothing to
  dispatch to, and the shared layer's own behaviour would be untestable. This
  is that stand-in, and it doubles as the executable statement of what a type
  owes the resolver.

  It is deliberately dull: `fake://{body}` parses to `{:fake, body}`, canonical
  identity is the source spelled back out, and authorization refuses exactly
  one body so both verdicts are reachable. `stat/1` and `ffmpeg_input/1` answer
  from the body too, since the seam's contract is what is under test, not any
  particular storage.
  """

  @behaviour AudioProxy.Source.Type

  @denied "denied"
  @missing "missing"
  @sizeless "sizeless"

  @impl true
  def scheme, do: "fake"

  @impl true
  def tag, do: :fake

  @impl true
  def parse(""), do: {:error, :empty_body}
  def parse(body), do: {:ok, {:fake, body}}

  @impl true
  def canonical({:fake, body}), do: "fake://" <> body

  @impl true
  def authorize({:fake, @denied}), do: {:error, :not_allowed}
  def authorize({:fake, _body}), do: :ok

  @impl true
  def stat({:fake, @missing}), do: {:error, :not_found}
  def stat({:fake, @sizeless}), do: {:ok, %{size: nil, etag: "etag-sizeless"}}
  def stat({:fake, body}), do: {:ok, %{size: byte_size(body), etag: "etag-" <> body}}

  @impl true
  def ffmpeg_input({:fake, @missing}), do: {:error, :not_found}
  def ffmpeg_input({:fake, body}), do: {:ok, "/fake/" <> body}

  @doc "The body `authorize/1` refuses."
  def denied, do: @denied

  @doc "The body `stat/1` and `ffmpeg_input/1` report as absent."
  def missing, do: @missing

  @doc "The body `stat/1` reports as present with an unknown size."
  def sizeless, do: @sizeless
end

defmodule AudioProxy.OtherFakeSourceType do
  @moduledoc """
  A second stand-in, so dispatch is tested against a table rather than a
  single entry — with one type registered, "picks the right one" and "picks
  the only one" are the same assertion.
  """

  @behaviour AudioProxy.Source.Type

  @impl true
  def scheme, do: "other"

  @impl true
  def tag, do: :other

  @impl true
  def parse(body), do: {:ok, {:other, body}}

  @impl true
  def canonical({:other, body}), do: "other://" <> body

  @impl true
  def authorize({:other, _body}), do: :ok

  @impl true
  def stat({:other, _body}), do: {:ok, %{size: 0, etag: nil}}

  @impl true
  def ffmpeg_input({:other, body}), do: {:ok, "other:" <> body}
end
