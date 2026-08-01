defmodule AudioProxy.RenderHarness do
  @moduledoc """
  Test helpers for driving `AudioProxy.Ffmpeg.Render` against `fake_cmd.sh`.

  Kept out of the test files because the hardening slice's orphan, timeout and
  classification tests consume the same three things: where the script lives,
  what bytes `emit` produces, and how to play the consumer's side of the
  message contract.
  """

  # The `emit` pattern from fake_cmd.sh: the block plus a newline, repeated.
  @block "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  @period byte_size(@block) + 1

  @doc "Absolute path to the fake subprocess."
  @spec fake_cmd() :: String.t()
  def fake_cmd, do: Path.expand("fake_cmd.sh", __DIR__)

  @doc """
  The exact bytes `fake_cmd.sh emit n` writes.

  A 63-byte period, so a reordering or a dropped chunk boundary shows up as a
  mismatch rather than as an equal-length blur.
  """
  @spec pattern(non_neg_integer()) :: binary()
  def pattern(0), do: ""

  def pattern(n) when n > 0 do
    (@block <> "\n")
    |> String.duplicate(div(n - 1, @period) + 1)
    |> binary_part(0, n)
  end

  @doc """
  Plays the consumer side until the render finishes, returning what it saw.

    * `{:ok, bytes, info}` on `{:done, _, info}`
    * `{:error, reason, bytes}` on `{:error, _, reason}`
    * `{:timeout, bytes}` if nothing more arrives within `:idle_timeout`
      (default 2000 ms) — which is the *expected* outcome when a test wants to
      show that forwarding has stopped

  Acknowledges every chunk unless `ack: false`, since a consumer that stops
  acking stops receiving.
  """
  @spec collect(pid(), keyword()) ::
          {:ok, binary(), map()} | {:error, term(), binary()} | {:timeout, binary()}
  def collect(render, opts \\ []) do
    ack? = Keyword.get(opts, :ack, true)
    idle_timeout = Keyword.get(opts, :idle_timeout, 2_000)

    collect(render, ack?, idle_timeout, [])
  end

  defp collect(render, ack?, idle_timeout, chunks) do
    receive do
      {:chunk, ^render, chunk} ->
        if ack?, do: AudioProxy.Ffmpeg.Render.ack(render, byte_size(chunk))
        collect(render, ack?, idle_timeout, [chunk | chunks])

      {:done, ^render, info} ->
        {:ok, joined(chunks), info}

      {:error, ^render, reason} ->
        {:error, reason, joined(chunks)}
    after
      idle_timeout -> {:timeout, joined(chunks)}
    end
  end

  defp joined(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
