defmodule AudioProxy.ArgvWalk do
  @moduledoc """
  Splits an ffmpeg argv into the tokens that occupy *flag* positions.

  The audio-only policy's headline claim is that no URL content can become an
  ffmpeg flag, and checking it means asking of every argv token: is this a flag,
  or an argument to one? "Starts with a hyphen" cannot answer that. `f:ogg/q:-1`
  renders `["-q:a", "-1"]`, because ogg's quality scale starts at −1 — so a
  leading-hyphen check would either report `-1` as an unknown flag (a false
  alarm that invites the assertion to be loosened) or be loosened *first* into
  something that no longer catches a real smuggled flag.

  So the argv is walked instead, in order, from a known start: position zero is
  a flag position, a flag that `AudioProxy.Ffmpeg.Command.takes_value?/1`
  reports takes one consumes the next element as its value, and everything else
  advances by one. What comes back is exactly the tokens ffmpeg would parse as
  options.

  Unrecognized flags are deliberately treated as taking no value. A token that
  is not in the vocabulary is the thing under test, so it must appear in the
  result — and guessing an arity for it would be inventing the answer.

  It lives in `test/support` rather than in `Command` because it is the
  *checking* half: `Command` publishes what it can emit, and this decides
  whether a given argv stayed inside that.
  """

  alias AudioProxy.Ffmpeg.Command

  @doc """
  The tokens in `argv` that sit in a flag position.

      iex> AudioProxy.ArgvWalk.flags(["-i", "-af", "-q:a", "-1", "pipe:1"])
      ["-i", "-q:a"]
  """
  @spec flags([String.t()]) :: [String.t()]
  def flags([]), do: []

  def flags([token | rest]) do
    cond do
      not String.starts_with?(token, "-") -> flags(rest)
      known_value_flag?(token) -> [token | flags(Enum.drop(rest, 1))]
      true -> [token | flags(rest)]
    end
  end

  defp known_value_flag?(token) do
    token in Command.allowed_flags() and Command.takes_value?(token)
  end
end
