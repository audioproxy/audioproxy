defmodule AudioProxy.FfprobeTest do
  @moduledoc """
  The contract mapping, against canned `ffprobe` output.

  These are the fixtures that pin §4's object shape per container, and canned
  is the point: the mapping's whole job is to absorb ffprobe's version- and
  format-dependent spellings, so exercising it against one installed binary
  would test exactly the one shape that never surprises us. What the real
  binary is for is `AudioProxy.InfoEndpointFfmpegTest`, which proves these
  fixtures still resemble what ffprobe emits.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Ffprobe

  doctest AudioProxy.Ffprobe

  # A 48 kHz stereo 16-bit WAV, as ffprobe describes one. Every fixture below
  # is this with the fields that container actually differs in replaced, so a
  # test reads as the difference it is about.
  defp wav do
    %{
      "streams" => [
        %{
          "codec_type" => "audio",
          "codec_name" => "pcm_s16le",
          "sample_rate" => "48000",
          "channels" => 2,
          "bits_per_sample" => 16,
          "bit_rate" => "1536000"
        }
      ],
      "format" => %{
        "format_name" => "wav",
        "duration" => "5.015000",
        "size" => "962924",
        "bit_rate" => "1536000"
      }
    }
  end

  defp probe(streams, format) do
    %{
      "streams" => [Map.merge(hd(wav()["streams"]), streams)],
      "format" => Map.merge(wav()["format"], format)
    }
  end

  describe "the §4 object" do
    test "a WAV reports every field the contract has for a lossless source" do
      assert {:ok, info} = Ffprobe.contract(wav())

      assert info == %{
               format: "wav",
               duration: 5.015,
               sample_rate: 48_000,
               channels: 2,
               bit_depth: 16,
               bitrate: 1_536_000,
               size: 962_924
             }
    end

    test "a lossy source has a bitrate and no bit depth" do
      probe =
        probe(
          %{"codec_name" => "mp3", "sample_rate" => "44100", "bits_per_sample" => 0},
          %{"format_name" => "mp3", "bit_rate" => "128000"}
        )

      assert {:ok, info} = Ffprobe.contract(probe)
      assert info.format == "mp3"
      assert info.bitrate == 128_000
      refute Map.has_key?(info, :bit_depth)
    end

    test "flac reports its depth through bits_per_raw_sample" do
      probe =
        probe(
          %{"codec_name" => "flac", "bits_per_sample" => 0, "bits_per_raw_sample" => "24"},
          %{"format_name" => "flac"}
        )

      assert {:ok, %{bit_depth: 24, format: "flac"}} = Ffprobe.contract(probe)
    end

    test "bits_per_raw_sample wins over bits_per_sample when both are set" do
      probe = probe(%{"bits_per_sample" => 32, "bits_per_raw_sample" => 24}, %{})

      assert {:ok, %{bit_depth: 24}} = Ffprobe.contract(probe)
    end

    test "a multichannel source reports its channel count" do
      probe = probe(%{"channels" => 6, "sample_rate" => "96000"}, %{})

      assert {:ok, %{channels: 6, sample_rate: 96_000}} = Ffprobe.contract(probe)
    end
  end

  describe "format is the API's vocabulary, not the demuxer's" do
    test "the mp4 family collapses to m4a" do
      probe =
        probe(%{"codec_name" => "aac"}, %{"format_name" => "mov,mp4,m4a,3gp,3g2,mj2"})

      assert {:ok, %{format: "m4a"}} = Ffprobe.contract(probe)
    end

    test "ogg is ogg for vorbis and opus for opus" do
      vorbis = probe(%{"codec_name" => "vorbis"}, %{"format_name" => "ogg"})
      opus = probe(%{"codec_name" => "opus"}, %{"format_name" => "ogg"})

      assert {:ok, %{format: "ogg"}} = Ffprobe.contract(vorbis)
      assert {:ok, %{format: "opus"}} = Ffprobe.contract(opus)
    end

    test "an unknown container falls through to its first name" do
      probe = probe(%{"codec_name" => "pcm_s16be"}, %{"format_name" => "aiff"})

      assert {:ok, %{format: "aiff"}} = Ffprobe.contract(probe)
    end

    test "a container ffprobe did not name is omitted rather than guessed" do
      probe = probe(%{}, %{"format_name" => nil})

      assert {:ok, info} = Ffprobe.contract(probe)
      refute Map.has_key?(info, :format)
    end
  end

  describe "unknown fields are omitted, never null" do
    test "N/A and missing values drop their keys" do
      probe = %{
        "streams" => [%{"codec_type" => "audio", "codec_name" => "mp3", "sample_rate" => "N/A"}],
        "format" => %{"format_name" => "mp3"}
      }

      assert {:ok, info} = Ffprobe.contract(probe)
      assert info == %{format: "mp3"}
    end

    test "a zero bit depth is a source without one, not a depth of zero" do
      probe = probe(%{"bits_per_sample" => 0, "bits_per_raw_sample" => 0}, %{})

      assert {:ok, info} = Ffprobe.contract(probe)
      refute Map.has_key?(info, :bit_depth)
    end

    test "duration falls back to the stream when the format has none" do
      probe = probe(%{"duration" => "9.5"}, %{"duration" => "N/A"})

      assert {:ok, %{duration: 9.5}} = Ffprobe.contract(probe)
    end
  end

  describe "size" do
    test "the stat size wins over ffprobe's" do
      assert {:ok, %{size: 4242}} = Ffprobe.contract(wav(), size: 4242)
    end

    test "ffprobe's is the fallback when the backend does not know one" do
      assert {:ok, %{size: 962_924}} = Ffprobe.contract(wav(), size: nil)
    end
  end

  describe "tags" do
    test "string-valued format tags pass through with lowercased keys" do
      probe = probe(%{}, %{"tags" => %{"TITLE" => "Sea Change", "artist" => "Test Artist"}})

      assert {:ok, %{tags: %{"title" => "Sea Change", "artist" => "Test Artist"}}} =
               Ffprobe.contract(probe)
    end

    test "non-string values are dropped" do
      probe = probe(%{}, %{"tags" => %{"title" => "ok", "weird" => %{"nested" => true}}})

      assert {:ok, %{tags: tags}} = Ffprobe.contract(probe)
      assert tags == %{"title" => "ok"}
    end

    test "an absent or empty tag block omits the key entirely" do
      assert {:ok, info} = Ffprobe.contract(probe(%{}, %{"tags" => %{}}))
      refute Map.has_key?(info, :tags)

      assert {:ok, info} = Ffprobe.contract(wav())
      refute Map.has_key?(info, :tags)
    end

    test "a pathological tag block is capped in both count and length" do
      tags = Map.new(1..100, fn n -> {"tag#{String.pad_leading("#{n}", 3, "0")}", "x"} end)
      long = Map.put(tags, "title", String.duplicate("é", 5_000))

      assert {:ok, %{tags: capped}} = Ffprobe.contract(probe(%{}, %{"tags" => long}))

      assert map_size(capped) == 32
      # Sorted before the cap, so which tags survive is the source's property:
      # "tag001".."tag031" and "title" would not both fit, and the sort decides.
      assert Enum.all?(Map.values(capped), &(String.length(&1) <= 512))
    end
  end

  describe "nothing to describe" do
    test "a probe with no audio stream is undecodable" do
      probe = %{"streams" => [], "format" => %{"format_name" => "mov,mp4,m4a,3gp,3g2,mj2"}}

      assert Ffprobe.contract(probe) == {:error, :undecodable_source}
    end

    test "a video-only stream is not an audio stream" do
      probe = %{
        "streams" => [%{"codec_type" => "video", "codec_name" => "h264"}],
        "format" => %{"format_name" => "mov,mp4,m4a,3gp,3g2,mj2"}
      }

      assert Ffprobe.contract(probe) == {:error, :undecodable_source}
    end

    test "output with no streams key at all is undecodable, not a crash" do
      assert Ffprobe.contract(%{}) == {:error, :undecodable_source}
    end
  end
end
