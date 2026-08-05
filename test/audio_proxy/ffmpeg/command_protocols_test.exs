defmodule AudioProxy.Ffmpeg.CommandProtocolsTest do
  @moduledoc """
  The one protocol set that is not a constant: `s3://`.

  `AudioProxy.Ffmpeg.Command.protocols/1` answers `:local` and `:http` from a
  literal, and `AudioProxy.Ffmpeg.CommandTest` covers those. The `:s3` clause
  reads `AP_S3_ENDPOINT`, because the presigned URL ffmpeg is handed carries the
  endpoint's own scheme — `ex_aws` builds it from exactly that value — so this
  file is `async: false` and lives apart from the pure ones.

  It is not a formality. A development deployment against MinIO is configured
  `AP_S3_ENDPOINT=http://minio:9000` and every presigned URL it mints is
  cleartext; a whitelist of `https,tls,tcp` would refuse the lot, and the
  failure would arrive as ffmpeg declining to open its input rather than as
  anything naming the whitelist. The container smoke suite renders an `s3://`
  source over exactly that endpoint, so the two have to agree.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Config
  alias AudioProxy.Ffmpeg.Command

  defp with_endpoint(endpoint) do
    put_config(%{s3: Map.put(Config.get(:s3), :endpoint, endpoint)})
  end

  describe "protocols/1 for an s3:// source" do
    test "against AWS — no endpoint — it is TLS only" do
      with_endpoint(nil)

      assert Command.protocols(:s3) == "https,tls,tcp"
      refute Command.protocols(:s3) =~ "file"
    end

    test "against an HTTPS endpoint it is still TLS only" do
      with_endpoint(URI.parse("https://s3.example.test"))

      assert Command.protocols(:s3) == "https,tls,tcp"
    end

    test "against a cleartext endpoint it gains http, and nothing else" do
      # The MinIO shape, and the reason this clause reads config at all.
      with_endpoint(URI.parse("http://minio:9000"))

      protocols = Command.protocols(:s3) |> String.split(",") |> MapSet.new()

      assert MapSet.equal?(protocols, MapSet.new(~w(https tls tcp http)))
    end

    test "no endpoint scheme can put file in the set" do
      for endpoint <- [nil, URI.parse("http://minio:9000"), URI.parse("https://s3.example.test")] do
        with_endpoint(endpoint)

        refute "file" in String.split(Command.protocols(:s3), ",")
      end
    end

    # The argv is what actually reaches ffmpeg, so assert there too rather than
    # trusting that `build/3` passes the set through.
    test "the set reaches the argv, before the input" do
      with_endpoint(URI.parse("http://minio:9000"))

      {:ok, options} = AudioProxy.Options.parse("f:mp3/br:96")

      argv =
        Command.build(options, "http://minio:9000/masters/a.wav?X-Amz-Signature=x", type: :s3)

      flag = Enum.find_index(argv, &(&1 == "-protocol_whitelist"))

      assert flag < Enum.find_index(argv, &(&1 == "-i"))
      assert Enum.at(argv, flag + 1) == Command.protocols(:s3)
    end
  end
end
