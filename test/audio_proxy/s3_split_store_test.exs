defmodule AudioProxy.S3SplitStoreTest do
  @moduledoc """
  Sources on one store, variants on another, end to end.

  Two claims, and neither can be made against a single endpoint. That **source
  requests go to the source's store under the source's identity**, which MinIO
  verifies by signature — a wrong credential there is a refused request, not an
  assertion. And that **store requests go somewhere else entirely under an
  identity of their own**, which is what `AudioProxy.CapturingStore` is for:
  MinIO can say a signature is valid, but it cannot be asked *whose* it was.

  The two halves check each other. If a store operation ever borrowed the
  source profile, the capture would record MinIO's access key and fail here; if
  a source operation borrowed the store profile, MinIO would refuse the
  signature and the render would 502. So a single wrong profile in either
  direction fails this file, which is the property the split exists to have.

  The encoder is `AudioProxy.FakeFfmpeg`, for the reason
  `AudioProxy.Source.S3BackendTest` gives: what changed is which credentials
  sign which request, and ffmpeg has no opinion about that. The source *stat*
  and the *presign* handed to it are both real requests against MinIO.

  Tagged `:minio`, excluded by default, failing rather than skipping when the
  store is absent.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.Eventually
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.SignedRequest, except: [conn: 3]
  import Plug.Test

  alias AudioProxy.{CapturingStore, MinioHelper, S3, VariantStore}

  @moduletag :minio
  @moduletag timeout: 120_000

  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  @source_bucket "audio-proxy-test"
  @store_bucket "audio-proxy-variants"

  @body "RIFF-fake-wav-bytes"

  # MinIO's, and the only credential in this file that is real. Anything the
  # capture receives signed with it is a store request that reached for the
  # source's identity.
  @source_key_id "minioadmin"

  # The store's, which no store verifies: the capture records it, and its whole
  # job is to be *distinguishable* from the one above.
  @store_key_id "STOREKEYEXAMPLE"

  setup do
    endpoint = MinioHelper.endpoint()
    %{endpoint: store_endpoint} = CapturingStore.start!()

    put_config(
      base_config(
        local_root: nil,
        presign_ttl: 900,
        source_allowlist: [],
        variant_store: {:s3, @store_bucket},
        serve_mode: :proxy,
        s3: %{
          region: "us-east-1",
          access_key_id: @source_key_id,
          secret_access_key: "minioadmin",
          session_token: nil,
          endpoint: endpoint,
          addressing: :path,
          ca_bundle: nil
        },
        variant_s3: %{
          region: "eu-west-1",
          access_key_id: @store_key_id,
          secret_access_key: "store-secret",
          session_token: nil,
          endpoint: store_endpoint,
          addressing: :path,
          ca_bundle: nil
        }
      )
    )

    MinioHelper.ensure_bucket!(@source_bucket)
    reset_coordinators()
    reset_probes()

    # Written with the *source* profile, which is the one that can reach MinIO.
    key = "split-store/#{System.unique_integer([:positive])}/piece.wav"
    :ok = S3.put_stream(@source_bucket, key, [@body])

    # The capture is only interesting from here on: the setup's own writes are
    # source-side and would otherwise read as store traffic.
    CapturingStore.reset!()

    {:ok, key: key, store_endpoint: store_endpoint}
  end

  describe "a render across two providers" do
    test "completes, and writes back to the store endpoint", %{key: key} do
      conn = render(key)

      assert conn.status == 200
      assert conn.resp_body == "fake-audio-payload"

      # The write-back is the tee's, which outlives the response by design.
      assert wait_until(fn -> Enum.any?(CapturingStore.requests(), &(&1.method == "PUT")) end)

      assert [put] = Enum.filter(CapturingStore.requests(), &(&1.method == "PUT"))
      assert put.path =~ @store_bucket
    end

    test "the source credential never signs a store request", %{key: key} do
      render(key)

      assert wait_until(fn -> Enum.any?(CapturingStore.requests(), &(&1.method == "PUT")) end)

      # The claim itself: every request that reached the store endpoint was
      # signed by the store's identity, and none by the source's.
      assert CapturingStore.access_keys() == [@store_key_id]
      refute @source_key_id in CapturingStore.access_keys()
    end

    test "and the two identities are independent knobs", %{key: key} do
      # The direction the capture cannot see. MinIO verifies signatures, so the
      # 200 above is already proof that the source side signed with the
      # source's credential — nothing else would have been let in. What is left
      # to show is that the two do not move together: breaking the source
      # identity alone stops the render, and leaves the store's untouched.
      assert render(key).status == 200

      put_config(%{s3: %{AudioProxy.Config.get(:s3) | secret_access_key: "wrong-secret"}})
      reset_coordinators()

      # The blind 404: a refused credential must not be distinguishable from a
      # missing object, which is `AudioProxy.Source.S3BackendTest`'s row.
      assert render(key).status == 404
      assert AudioProxy.Config.get(:variant_s3).access_key_id == @store_key_id
    end
  end

  describe "a redirect-mode HIT under split configuration" do
    setup do
      put_config(%{serve_mode: :redirect})
      CapturingStore.serve_hits!()
      :ok
    end

    test "presigns against the store's endpoint and identity", %{
      key: key,
      store_endpoint: store_endpoint
    } do
      conn = render(key)

      assert conn.status == 302
      assert [location] = Plug.Conn.get_resp_header(conn, "location")

      uri = URI.parse(location)

      # The host is inside the SigV4 signature, so this is not a preference:
      # a HIT signed for the source's endpoint is a URL no store can verify.
      assert uri.host == store_endpoint.host
      assert uri.port == store_endpoint.port
      assert URI.decode_query(uri.query)["X-Amz-Credential"] =~ @store_key_id
      refute URI.decode_query(uri.query)["X-Amz-Credential"] =~ @source_key_id
    end

    test "the store backend's presign agrees with it" do
      # Same claim one layer down, without the endpoint's HEAD in the way, so a
      # failure says which of the two is wrong.
      assert {:ok, url} = VariantStore.presign(String.duplicate("ab", 32), expires_in: 900)

      assert URI.parse(url).host == "127.0.0.1"
      assert URI.decode(url) =~ @store_key_id
    end
  end

  describe "a proxy-mode HIT under split configuration" do
    setup do
      CapturingStore.serve_hits!()
      :ok
    end

    test "reads the variant back from the store, not from the source's", %{key: key} do
      conn = render(key)

      assert conn.status == 200
      assert header(conn, "x-audio-proxy") == "HIT"
      # The bytes came off the store endpoint rather than being re-rendered:
      # a MISS here would carry the fake encoder's payload instead.
      assert conn.resp_body == CapturingStore.body()
    end

    test "the read is ranged, and signed by the store", %{key: key} do
      render(key)

      gets = Enum.filter(CapturingStore.requests(), &(&1.method == "GET"))

      # Proxy-mode serving is a sequence of ranged GETs — the fourth and last
      # store operation, and the one that held only by construction until this
      # test existed.
      assert [_first | _rest] = gets
      assert Enum.all?(gets, &(&1.range =~ ~r/^bytes=\d+-\d+$/))
      assert CapturingStore.access_keys() == [@store_key_id]
    end
  end

  ## Driving the flows

  # The capture reports an empty store until a test calls `serve_hits!/0`, so
  # this is a MISS — a real render followed by a write-back — everywhere above
  # except the redirect describe, which is about serving a HIT.
  defp render(key), do: request("/f:mp3/plain/s3://#{@source_bucket}/#{key}")

  defp request(rest) do
    conn(:get, signed(rest)) |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end
end
