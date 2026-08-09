defmodule AudioProxy.Llms do
  @moduledoc """
  The [llms.txt](https://llmstxt.org) documents, embedded at compile time.

  Two files under `priv/llms`: `llms.txt`, the index — an H1, a blockquote
  summary, and sectioned link lists — and `llms-full.txt`, the whole API
  reference in one document, so an agent that fetches it needs no follow-up
  request to construct a correct signed URL.

  They are read into module attributes rather than off disk per request. That
  buys three things: the release carries them without depending on a
  `priv` directory surviving the image build, a request costs no filesystem
  access, and `@external_resource` makes a doc edit recompile this module, so
  the drift guards in `test/audio_proxy/llms_test.exs` run against what would
  actually be served.

  Those guards are why `llms-full.txt` has machine-checked regions: its option
  table must name exactly `AudioProxy.Options.keys/0`, and its error table
  exactly `AudioProxy.ErrorJSON.rows/0`. The file's own header comment states
  the shape they parse. Prose stays human-owned; only coverage is enforced.
  """

  @dir Path.expand("../../priv/llms", __DIR__)

  @index_path Path.join(@dir, "llms.txt")
  @full_path Path.join(@dir, "llms-full.txt")

  @external_resource @index_path
  @external_resource @full_path

  @index File.read!(@index_path)
  @full File.read!(@full_path)

  @doc "The `/llms.txt` index document."
  @spec index() :: String.t()
  def index, do: @index

  @doc "The `/llms-full.txt` complete reference."
  @spec full() :: String.t()
  def full, do: @full
end
