defmodule AudioProxy.Ffmpeg.CommandPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import AudioProxy.OptionsGenerators, only: [option_segments: 0]

  alias AudioProxy.ArgvWalk
  alias AudioProxy.CacheKey
  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.Options

  doctest AudioProxy.ArgvWalk

  @source "s3://masters/2026/piece-final.wav"
  @input "https://masters.example/2026/piece-final.wav?X-Amz-Signature=deadbeef"

  defp build(segments, input \\ @input, type \\ :http) do
    {:ok, opts} = Options.parse(segments)
    Command.build(opts, input, type: type)
  end

  # This is the invariant the whole project rests on: the cache key promises
  # that a variant already rendered is byte-identical to the one being asked
  # for, and that promise is only worth anything if equal keys imply equal
  # ffmpeg commands. It closes the loop parse → normalize → key → argv.
  property "segment order does not reach the argv" do
    check all(segments <- option_segments(), permuted <- shuffle(segments)) do
      assert build(segments) == build(permuted)
    end
  end

  # Two independent draws essentially never collide, so guarding on a collision
  # would make this assertion almost never run — a property that reads like it
  # tests the headline invariant while testing nothing. Instead, re-spell one
  # variant (its own normalized form is a different string that must describe
  # the same thing) and require the implication to hold on a pair that is
  # guaranteed to collide.
  property "equal cache keys imply identical argv" do
    check all(segments <- option_segments()) do
      assert {:ok, normalized} = Options.normalize_string(segments)

      assert CacheKey.derive(segments, @source) == CacheKey.derive(normalized, @source)
      assert build(segments) == build(normalized)
    end
  end

  # The `-0` regression, as a property rather than an example: any spelling that
  # normalizes to the same string must build the same command, and `-0` is the
  # spelling that used to normalize alike and build differently.
  property "a signed zero builds what an unsigned zero builds" do
    check all(
            segments <- option_segments(),
            key <- member_of(["gain", "fade", "t"])
          ) do
      base = Enum.reject(segments, &String.starts_with?(&1, key <> ":"))
      signed = base ++ ["#{key}:-0"]
      unsigned = base ++ ["#{key}:0"]

      with {:ok, _} <- Options.parse(signed), {:ok, _} <- Options.parse(unsigned) do
        assert Options.normalize_string(signed) == Options.normalize_string(unsigned)
        assert build(signed) == build(unsigned)
      end
    end
  end

  # The converse does not hold, and should not: `dl` changes a response
  # header, `cb` is a deliberate cache-buster, and `pts`/`pk_fmt` govern the
  # reduction applied *after* ffmpeg. All four are part of the variant's
  # identity without being part of its render, so identical argv under
  # distinct keys is the design working, not a collision.
  property "options outside the render still separate cache keys" do
    check all(
            segments <- option_segments(),
            buster <- string(?a..?z, min_length: 1, max_length: 8)
          ) do
      segments = Enum.reject(segments, &String.starts_with?(&1, "cb:"))
      busted = segments ++ ["cb:#{buster}"]

      assert build(segments) == build(busted)
      assert CacheKey.derive(segments, @source) != CacheKey.derive(busted, @source)
    end
  end

  # No shell means no shell metacharacters to worry about — but only as long
  # as every element really is a complete, standalone argument. An empty
  # string or a nil would be handed to execve as an argument all the same,
  # and a nested list would not survive Port.open/2 at all.
  property "argv is a flat list of non-empty binaries" do
    check all(segments <- option_segments()) do
      argv = build(segments)

      assert is_list(argv)

      for argument <- argv do
        assert is_binary(argument)
        assert argument != ""
        refute is_nil(argument)
      end
    end
  end

  property "the opaque options never reach the argv" do
    check all(
            segments <- option_segments(),
            name <- string(?a..?z, min_length: 1, max_length: 8),
            buster <- string(?a..?z, min_length: 1, max_length: 8)
          ) do
      bare = Enum.reject(segments, &String.starts_with?(&1, ["dl:", "cb:"]))
      opaque = bare ++ ["dl:#{name}.mp3", "cb:#{buster}"]

      # `dl` sets a response header and `cb` sets nothing at all; neither
      # describes the render, so adding both must leave the command untouched.
      assert build(opaque) == build(bare)
    end
  end

  # The filtergraph is the one argument assembled by concatenation, so it is
  # the one place a stray separator would change ffmpeg's parse of it. Every
  # value in it comes from a bounded numeric option, so the whole string is
  # drawn from a tiny alphabet.
  property "the filtergraph holds only filter names, numbers and separators" do
    check all(segments <- option_segments()) do
      argv = build(segments)

      case Enum.find_index(argv, &(&1 == "-af")) do
        nil ->
          :ok

        index ->
          assert Enum.at(argv, index + 1) =~ ~r/^[a-zA-Z0-9_=:,.\-]+$/
      end
    end
  end

  property "the input URL survives verbatim, whatever it contains" do
    check all(
            segments <- option_segments(),
            input <- string(:printable, min_length: 1, max_length: 60)
          ) do
      argv = build(segments, input)
      index = Enum.find_index(argv, &(&1 == "-i"))

      assert Enum.at(argv, index + 1) == input

      # The URL is the only element that varies; everything else is identical
      # to the same options built against a benign input.
      assert List.replace_at(argv, index + 1, @input) == build(segments)
    end
  end

  property "every argv writes to stdout behind an explicit muxer" do
    check all(segments <- option_segments()) do
      assert ["-f", muxer, "pipe:1"] = build(segments) |> Enum.take(-3)
      assert muxer =~ ~r/^[a-z0-9]+$/
    end
  end

  # The audio-only policy's central claim, as a property: whatever options a
  # signed URL carries, every flag ffmpeg is handed came from this module's own
  # vocabulary. Reality ⊆ allowlist — the other direction (allowlist ∩ denylist
  # = ∅) is an example test, since it is a statement about a fixed list.
  property "every flag in a built argv is in the published allowlist" do
    check all(segments <- option_segments()) do
      assert ArgvWalk.flags(build(segments)) -- Command.allowed_flags() == []
    end
  end

  property "every argv disables video, subtitles and data, whatever the options" do
    check all(segments <- option_segments()) do
      argv = build(segments)

      assert "-vn" in argv
      assert "-sn" in argv
      assert "-dn" in argv
    end
  end

  property "every argv restricts input protocols, before the input" do
    check all(segments <- option_segments(), type <- member_of([:local, :http])) do
      argv = build(segments, @input, type)
      flag = Enum.find_index(argv, &(&1 == "-protocol_whitelist"))

      assert flag < Enum.find_index(argv, &(&1 == "-i"))
      assert Enum.at(argv, flag + 1) == Command.protocols(type)
    end
  end

  # The opaque options are where a flag would be smuggled if it could be: `dl`
  # is arbitrary text and `cb` is arbitrary text, and both are refused only for
  # control characters. Neither reaches argv at all — so a value spelled exactly
  # like a flag stays out of it, and the argv is identical to one built without
  # them.
  property "a flag spelled into dl or cb never becomes a flag" do
    check all(
            segments <- option_segments(),
            smuggled <-
              member_of([
                "-filter_complex",
                "-vf",
                "-map",
                "-c:v",
                "-protocol_whitelist",
                "-i",
                "--",
                "-f concat"
              ])
          ) do
      bare = Enum.reject(segments, &String.starts_with?(&1, ["dl:", "cb:"]))
      opaque = bare ++ ["dl:#{smuggled}", "cb:#{smuggled}"]

      # Either validation refuses the spelling outright (a 422 before argv
      # exists), or the argv is byte-identical to the one without it.
      with {:ok, opts} <- Options.parse(opaque) do
        argv = Command.build(opts, @input, type: :http)

        # Byte-identical to the argv without the smuggled spelling — which is
        # the strongest form of "it did not reach argv", and holds even when the
        # spelling is a flag this module legitimately emits of its own accord.
        assert argv == build(bare)
        assert ArgvWalk.flags(argv) -- Command.allowed_flags() == []
      end
    end
  end

  # The other half of the smuggling surface: the *input*, which is the one argv
  # element derived from a source a client named. A flag-shaped input is one
  # argument in a value position and changes nothing else.
  property "a flag-shaped input stays a value" do
    check all(
            segments <- option_segments(),
            input <- member_of(["-vf", "-map", "-i", "--", "-protocol_whitelist", "-y"])
          ) do
      argv = build(segments, input)
      index = Enum.find_index(argv, &(&1 == "-i"))

      assert Enum.at(argv, index + 1) == input
      assert ArgvWalk.flags(argv) -- Command.allowed_flags() == []
      assert List.replace_at(argv, index + 1, @input) == build(segments)
    end
  end

  property "every variant has a content type" do
    check all(segments <- option_segments()) do
      {:ok, opts} = Options.parse(segments)

      assert Command.content_type(opts) =~ ~r"^[a-z]+/[a-z0-9.+-]+$"
    end
  end
end
