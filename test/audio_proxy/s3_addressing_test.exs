defmodule AudioProxy.S3AddressingTest do
  @moduledoc """
  What URL each addressing style actually produces, on both call sites.

  Untagged and storeless on purpose. Neither Tigris nor AWS is reachable from
  CI, and MinIO — the one store the suite can talk to — is happy with
  path-style, which is exactly the configuration that already worked. So the
  virtual-hosted decision cannot be pinned by a round trip here at all.

  What it can be pinned by is the URL: request building and presigning are
  both pure local computation, so this asserts on the bytes that would go on
  the wire. Weaker evidence than a real fetch, and `docs/s3-providers.md`
  says so — but it does catch the failure this change exists to prevent, and
  it catches it deterministically.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Config
  alias AudioProxy.S3

  @bucket "variants"
  @key "abc/def.mp3"

  # The request path builds its URL inside `ExAws.Operation.S3`'s protocol
  # implementation, so that is what gets driven — the alternative is asserting
  # on `virtual_host: true` and calling it a URL test, which is the assumption
  # under review rather than a check of it.
  @operation_impl ExAws.Operation.ExAws.Operation.S3

  describe "virtual-hosted addressing" do
    setup do: configure(:virtual)

    test "a request puts the bucket in the host and the key alone in the path" do
      assert request_url() == "https://variants.example-store.test/abc/def.mp3"
    end

    test "a presigned URL agrees with it" do
      assert {:ok, url} = S3.presign_get(@bucket, @key)
      uri = URI.parse(url)

      assert uri.host == "variants.example-store.test"
      assert uri.path == "/abc/def.mp3"
    end
  end

  describe "path-style addressing" do
    setup do: configure(:path)

    test "a request leads the path with the bucket" do
      assert request_url() == "https://example-store.test/variants/abc/def.mp3"
    end

    test "a presigned URL agrees with it" do
      assert {:ok, url} = S3.presign_get(@bucket, @key)
      uri = URI.parse(url)

      assert uri.host == "example-store.test"
      assert uri.path == "/variants/abc/def.mp3"
    end
  end

  describe "the two call sites" do
    # The sharpest failure this change can produce, and the one no round-trip
    # test would catch: writes go through the request path and would keep
    # working, while every redirect handed a client a URL signed for a host it
    # was not sent to. The host is inside the SigV4 signature, so such a URL is
    # not merely wrong — no store can verify it.
    for style <- [:virtual, :path] do
      test "#{style} addressing signs the host it would request" do
        configure(unquote(style))

        assert {:ok, url} = S3.presign_get(@bucket, @key)

        presigned = URI.parse(url)
        requested = URI.parse(request_url())

        assert presigned.host == requested.host
        assert presigned.path == requested.path
      end
    end
  end

  describe "config/0" do
    test "carries virtual_host only when addressing is virtual" do
      configure(:virtual)
      assert S3.config()[:virtual_host] == true

      configure(:path)
      assert S3.config()[:virtual_host] == false
    end
  end

  ## Fixture

  defp configure(addressing) do
    put_config(%{
      presign_ttl: 900,
      s3: %{
        region: "us-east-1",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        session_token: nil,
        endpoint: URI.parse("https://example-store.test"),
        addressing: addressing,
        ca_bundle: nil
      }
    })

    :ok
  end

  defp request_url do
    operation = ExAws.S3.get_object(@bucket, @key)
    config = ExAws.Config.new(:s3, S3.config())

    {operation, config} = @operation_impl.add_bucket_to_path(operation, config)

    operation
    |> @operation_impl.add_resource_to_params()
    |> ExAws.Request.Url.build(config)
  end

  # Guards the defaults this file's fixtures bypass: everything above sets
  # `addressing` explicitly, so without this a change to the default would
  # leave the whole file green.
  describe "the default" do
    test "is virtual-hosted with no endpoint and path-style with one" do
      env = %{
        "AWS_ACCESS_KEY_ID" => "id",
        "AWS_SECRET_ACCESS_KEY" => "secret",
        "AWS_REGION" => "us-east-1"
      }

      assert Config.build!(env).s3.addressing == :virtual

      assert Config.build!(Map.put(env, "AP_S3_ENDPOINT", "http://minio:9000")).s3.addressing ==
               :path
    end
  end
end
