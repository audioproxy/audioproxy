defmodule AudioProxy.CapturingStore do
  @moduledoc """
  A second S3 endpoint that answers plausibly and records who asked.

  The split-configuration suite needs two *different* endpoints reachable from
  one test, and the devcontainer runs one MinIO. It also needs to assert
  something MinIO cannot be asked: **which identity signed each request**. A
  store that verifies a signature can only say yes or no; this one keeps the
  `Authorization` header, so a test can name the access key that arrived and
  fail on the wrong one.

  That is the whole trade, and it is worth stating plainly rather than
  discovering later: this endpoint **verifies nothing**. It is not a fake S3
  and must not grow into one — `AudioProxy.S3Test` explains at length why a
  stub that decides whether a signature is valid only ever agrees with the code
  that produced it. What it proves is *routing and identity*: that store
  requests went to the store's endpoint carrying the store's credential, which
  is exactly the claim a single-endpoint suite cannot make. The signature the
  source side produces is still verified, by MinIO, in the same test.

  ## Using it

      %{endpoint: endpoint} = CapturingStore.start!()
      put_config(%{variant_s3: %{... endpoint: endpoint, addressing: :path ...}})

      assert CapturingStore.access_keys() == ["STOREKEYEXAMPLE"]

  Path-style addressing only, for the reason `AudioProxy.MinioHelper` gives:
  the listener is on `127.0.0.1`, and `bucket.127.0.0.1` is not a name.
  """

  @behaviour Plug

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias AudioProxy.TestServer

  @table __MODULE__
  @mode_key {__MODULE__, :head_mode}

  # An object this store reports on a HEAD once `serve_hits!/0` is called, so
  # the redirect path can find a HIT without anything ever having been
  # written. The values are the seam's own: `AudioProxy.VariantStore.S3`
  # refuses an object missing any of them.
  @etag ~s("captured")
  @content_type "audio/ogg"
  @cache_control "public, max-age=31536000, immutable, no-transform"

  @typedoc "One captured request."
  @type request :: %{
          method: String.t(),
          path: String.t(),
          host: String.t(),
          authorization: String.t()
        }

  @doc """
  Boots the listener and returns its endpoint, empty of captures.

  The capture table is created here and dropped on exit, so a file booting
  this in `setup` gets one test's requests rather than the file's.
  """
  @spec start!() :: %{endpoint: URI.t(), port: :inet.port_number()}
  def start! do
    %{port: port} = TestServer.start!(__MODULE__)

    reset!()

    %{endpoint: URI.parse("http://127.0.0.1:#{port}"), port: port}
  end

  @doc """
  Forgets every captured request, and reports the store as empty again.

  A test that means to capture only the requests *it* provoked calls this
  after its own setup writes.
  """
  @spec reset!() :: :ok
  def reset! do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

    :ets.new(@table, [:named_table, :public, :duplicate_bag])
    :persistent_term.put(@mode_key, :empty)

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
      :persistent_term.erase(@mode_key)
    end)

    :ok
  end

  @doc """
  Makes every subsequent HEAD report a complete variant.

  Empty is the default, because the interesting path — render, then write back
  — only exists on a miss. A test about serving a HIT says so here rather than
  by writing an object this store would not have kept anyway.
  """
  @spec serve_hits!() :: :ok
  def serve_hits!, do: :persistent_term.put(@mode_key, :stored)

  @doc "Every request this endpoint received, oldest first."
  @spec requests() :: [request()]
  def requests do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The distinct access key ids that signed the captured requests.

  Parsed out of `Credential=<key>/<date>/<region>/s3/aws4_request`, which is
  SigV4's own spelling. An unsigned request contributes nothing rather than a
  `nil` — there is no such thing here, and a test asserting on the list should
  fail on the *wrong* key, not on a shape.
  """
  @spec access_keys() :: [String.t()]
  def access_keys do
    requests()
    |> Enum.flat_map(fn request ->
      case Regex.run(~r{Credential=([^/]+)/}, request.authorization) do
        [_match, key] -> [key]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    capture(conn)

    case conn.method do
      "HEAD" -> head(conn)
      "PUT" -> conn |> drain() |> Plug.Conn.put_resp_header("etag", @etag) |> ok()
      "DELETE" -> Plug.Conn.send_resp(conn, 204, "")
      # A GET here is a presigned URL being followed, or proxy-mode reading
      # back — neither is what this endpoint exists to observe, so it answers
      # the smallest legitimate thing.
      "GET" -> Plug.Conn.send_resp(conn, 200, "")
      _other -> conn |> drain() |> ok()
    end
  end

  defp head(conn) do
    case :persistent_term.get(@mode_key, :empty) do
      :stored -> stored(conn)
      :empty -> Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp stored(conn) do
    conn
    |> Plug.Conn.put_resp_header("etag", @etag)
    |> Plug.Conn.put_resp_header("content-type", @content_type)
    |> Plug.Conn.put_resp_header("cache-control", @cache_control)
    |> Plug.Conn.put_resp_header("x-amz-meta-etag", @etag)
    |> Plug.Conn.put_resp_header("content-length", "0")
    |> Plug.Conn.send_resp(200, "")
  end

  defp ok(conn), do: Plug.Conn.send_resp(conn, 200, "")

  # The body has to be read before a response is sent, or the client sees the
  # connection close under a request it was still writing — which surfaces as a
  # transport error in the code under test rather than as the 200 this store
  # meant to send.
  defp drain(conn) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, _body, conn} -> conn
      {:more, _partial, conn} -> drain(conn)
      {:error, _reason} -> conn
    end
  end

  # A variant write-back outlives the response that triggered it — that is the
  # tee's whole design — so a PUT can arrive after the test that provoked it has
  # exited and taken the table with it. Dropped rather than recorded: raising
  # here would surface inside the Bandit handler as an error in a test that has
  # already passed, which is exactly the kind of noise that gets diagnosed as a
  # real bug six months later.
  defp capture(conn) do
    request = %{
      method: conn.method,
      path: conn.request_path,
      host: conn.host,
      authorization: header(conn, "authorization")
    }

    :ets.insert(@table, {System.unique_integer([:monotonic]), request})
  rescue
    # `rescue` rather than a `whereis` check, which would still leave the
    # window between looking and inserting — and the table is owned by a
    # process that is on its way out, so that window is the whole risk.
    ArgumentError -> :ok
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> ""
    end
  end
end
