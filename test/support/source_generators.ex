defmodule AudioProxy.SourceGenerators do
  @moduledoc """
  StreamData generators for source bodies, in their *decoded* form.

  A body is everything after `scheme://`, which is precisely what
  `AudioProxy.Source` hands a source type. Generating bodies rather than whole
  sources keeps these properties about the shared layer: the encodings and the
  decode-once rule, not any particular source form.

  Bodies draw from the characters that make escaping interesting — space, `+`,
  `/`, `?`, `#`, `&`, `=`, `:`, brackets and braces — because those are exactly
  where a decode-twice or decode-never bug shows up.

  `body/0` leaves `%` out and `percent_body/0` puts it back, and the split is
  not squeamishness. A literal `%` survives decoding as a `%`, so a body like
  `%2F` is indistinguishable from an escape when read back out of a canonical
  string; it would make the "no percent-escapes" property fail on its own input
  rather than on a bug. Round-trip equivalence is the property that *can* see
  through it, so `percent_body/0` feeds that one.

  Control code points are excluded from both: the resolver refuses them, and
  that rejection is example-tested instead.
  """

  use ExUnitProperties

  @body_chars ~c"abcXYZ019 +/?#&=:.-_()[]{}!'~"

  @doc "A decoded source body: whatever follows `scheme://`."
  def body, do: nonempty_string(@body_chars, 40)

  @doc "A decoded body carrying at least one literal percent."
  def percent_body do
    gen all(prefix <- body(), suffix <- body()) do
      prefix <> "%" <> suffix
    end
  end

  defp nonempty_string(chars, max_length) do
    chars
    |> Enum.map(&<<&1::utf8>>)
    |> member_of()
    |> list_of(min_length: 1, max_length: max_length)
    |> map(&Enum.join/1)
  end
end
