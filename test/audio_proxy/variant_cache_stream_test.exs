defmodule AudioProxy.VariantCacheStreamTest do
  @moduledoc """
  The parts of a cache HIT that only exist on the wire.

  Two of them, and `Plug.Test` can show neither. *Framing*: a proxied HIT is
  length-delimited rather than chunked, which is the difference between a
  response a client can seek and resume and one it cannot — and from the conn
  both look like a 200 with a body. *Progressiveness*: that the bytes leave as
  they are read, so a 24 MiB variant starts playing immediately and never sits
  in the proxy's memory in one piece.

  So this binds Bandit on an ephemeral port and speaks HTTP/1.1 down a raw
  socket, exactly as `AudioProxy.RenderEndpointStreamTest` does for the render
  side. Tagged `:integration` for the same reason: the default run binds no
  sockets.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest

  alias AudioProxy.{CacheKey, RawHttp, VariantStore}

  @moduletag :integration
  @moduletag tmp_dir: "variant_cache_stream"

  @deadline 5_000

  @options "f:opus/br:96"
  @rest "/f:opus/br:96/plain/local://cached.wav"

  # Small enough to compare byte for byte, large enough to span several of the
  # store's 64 KiB reads.
  @variant :binary.copy("0123456789abcdef", 20_000)

  # Big enough that "did the proxy hold the whole thing" is a question the VM's
  # binary memory can answer over the noise of everything else running.
  @large_bytes 24 * 1024 * 1024

  setup %{tmp_dir: tmp_dir} do
    store = Path.join(tmp_dir, "store")
    File.mkdir_p!(store)

    put_config(
      base_config(local_root: tmp_dir, variant_store: {:file, store}, serve_mode: :proxy)
    )

    bandit =
      start_supervised!(
        {Bandit, plug: AudioProxy.FakeFfmpeg.Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    {:ok, port: port}
  end

  defp store!(bytes) do
    key = CacheKey.derive!(@options, "local://cached.wav")

    :ok =
      VariantStore.put_stream(key, [bytes], %{
        content_type: "audio/ogg",
        cache_control: "public, max-age=31536000, immutable, no-transform",
        etag: ~s("#{key}")
      })

    key
  end

  describe "framing" do
    test "a proxied HIT is length-delimited, not chunked", %{port: port} do
      store!(@variant)

      response = @rest |> signed() |> RawHttp.get(port) |> RawHttp.read(@deadline)

      assert response.head =~ "http/1.1 200 ok"
      assert response.head =~ "content-length: #{byte_size(@variant)}"
      assert response.head =~ "accept-ranges: bytes"
      assert response.head =~ "x-audio-proxy: hit"

      # The whole point of declaring a length: no chunk framing at all, so the
      # body off the socket is the variant and nothing else.
      refute response.head =~ "transfer-encoding"
      assert response.body == @variant
    end

    test "a Range on a HIT is a 206 with the slice, on the wire", %{port: port} do
      store!(@variant)

      response =
        @rest
        |> signed()
        |> get_with_range(port, "bytes=1000-1099")
        |> RawHttp.read(@deadline)

      assert response.head =~ "http/1.1 206"
      assert response.head =~ "content-range: bytes 1000-1099/#{byte_size(@variant)}"
      assert response.head =~ "content-length: 100"
      assert response.body == binary_part(@variant, 1000, 100)
    end
  end

  describe "progressive delivery" do
    test "bytes arrive before the store read completes, and are never all resident",
         %{port: port} do
      store!(:binary.copy(<<0>>, @large_bytes))

      # The 24 MiB this test just wrote is garbage now, and counting it in the
      # baseline would leave room for the server to hold a copy of its own for
      # free. Collect first, then measure.
      :erlang.garbage_collect()
      baseline = :erlang.memory(:binary)

      socket = RawHttp.get(signed(@rest), port)

      # One read, then stop: the socket's buffers cannot hold 24 MiB, so the
      # server is now blocked on a write, part-way through the variant. That
      # is the moment worth measuring — a proxy that read the object into
      # memory before sending would be holding all of it right now.
      assert {:ok, _first} = :gen_tcp.recv(socket, 0, @deadline)

      # 2 MiB, not a quarter of the variant. The store reads in 64 KiB chunks
      # and the socket buffers a little more, so anything near this bound is
      # read-ahead rather than streaming — the loose threshold this started
      # with would have passed an implementation buffering 5 MiB.
      resident = :erlang.memory(:binary) - baseline

      assert resident < 2 * 1024 * 1024,
             "the proxy is holding #{div(resident, 1024)} KiB of a #{div(@large_bytes, 1024 * 1024)} MiB variant"

      :ok = :gen_tcp.close(socket)
    end

    test "a client that leaves mid-hit is not an error", %{port: port} do
      store!(:binary.copy(<<0>>, @large_bytes))

      socket = RawHttp.get(signed(@rest), port)
      assert {:ok, _first} = :gen_tcp.recv(socket, 0, @deadline)
      :ok = :gen_tcp.close(socket)

      # Nothing to assert about the departed request itself — what matters is
      # that the server is still serving, rather than having taken a crash out
      # of a write to a closed socket.
      store!(@variant)
      response = @rest |> signed() |> RawHttp.get(port) |> RawHttp.read(@deadline)

      assert response.head =~ "http/1.1 200 ok"
      assert response.body == @variant
    end
  end

  defp get_with_range(path, port, range) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: localhost\r\nRange: #{range}\r\nConnection: close\r\n\r\n"
      )

    socket
  end
end
