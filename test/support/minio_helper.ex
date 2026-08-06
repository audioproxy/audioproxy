defmodule AudioProxy.MinioHelper do
  @moduledoc """
  Pointing the config at the MinIO the `:minio` suite runs against, and making
  sure a bucket is there.

  `AudioProxy.S3Test` predates this and keeps its own copies — it is the suite
  that tests the client itself, and its fixtures do more (part listings,
  multipart inspection) than anything here needs. What this exists for is the
  suites *above* the client: the variant-store parity run and the end-to-end
  redirect check, which both want the same three lines of setup and neither of
  which is about S3 in itself.

  Every function raises rather than skipping when the store is absent. A green
  run against nothing is a lie about coverage — see `test/test_helper.exs`.
  """

  import ExUnit.Assertions

  alias AudioProxy.{Config, ConfigHelper, S3}

  @doc "The endpoint the `:minio` suite talks to, defaulting to the devcontainer's."
  @spec endpoint() :: URI.t()
  def endpoint do
    URI.parse(System.get_env("AP_TEST_MINIO_ENDPOINT", "http://minio:9000"))
  end

  @doc """
  Puts the MinIO credentials into the config and proves the store is up.

  `overrides` is merged over the config afterwards, which is where a caller
  puts its `:variant_store` or a different `:serve_mode`.
  """
  @spec configure!(map()) :: URI.t()
  def configure!(overrides \\ %{}) do
    endpoint = endpoint()
    ensure_reachable!(endpoint)

    ConfigHelper.put_config(
      Map.merge(
        %{
          presign_ttl: 900,
          s3: %{
            region: "us-east-1",
            access_key_id: "minioadmin",
            secret_access_key: "minioadmin",
            session_token: nil,
            endpoint: endpoint,
            # MinIO is reached by hostname and port, so `bucket.minio` would
            # want DNS nobody configured. Virtual-hosted addressing is
            # `AudioProxy.S3AddressingTest`'s to cover.
            addressing: :path,
            ca_bundle: nil
          }
        },
        overrides
      )
    )

    endpoint
  end

  @doc """
  Creates `bucket` if it is not already there.

  200 the first time; every run after, the store reports it as already owned.
  Anything else is a real failure — wrong credentials, a store that will not
  accept writes — and is raised here rather than left to surface as a
  confusing assertion three tests later.
  """
  @spec ensure_bucket!(String.t()) :: :ok
  def ensure_bucket!(bucket) do
    case bucket |> ExAws.S3.put_bucket(Config.get(:s3).region) |> ExAws.request(S3.config()) do
      {:ok, _response} ->
        :ok

      {:error, {:http_error, 409, %{body: body}}} ->
        unless body =~ "BucketAlreadyOwnedByYou" or body =~ "BucketAlreadyExists" do
          raise "could not create the #{bucket} bucket: #{body}"
        end

        :ok

      other ->
        raise "could not create the #{bucket} bucket: #{inspect(other)}"
    end
  end

  @doc "A plain unsigned GET, for following a presigned URL from a test."
  @spec fetch(String.t()) :: {non_neg_integer(), map(), binary()}
  def fetch(url) do
    assert {:ok, {{_version, status, _reason}, headers, body}} =
             :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    headers = Map.new(headers, fn {name, value} -> {to_string(name), to_string(value)} end)

    {status, headers, body}
  end

  # `:httpc` directly, which is also what `AudioProxy.S3.HttpClient` drives — so
  # a probe here is the same stack the proxy uses, minus the signing.
  defp ensure_reachable!(endpoint) do
    url = URI.to_string(%{endpoint | path: "/minio/health/live"})

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [connect_timeout: 2_000, timeout: 5_000],
           []
         ) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        :ok

      other ->
        raise """
        MinIO is not reachable at #{URI.to_string(endpoint)} (#{inspect(other)}).

        These tests are tagged :minio and excluded by default; running them
        requires a store. See docs/development.md, or set
        AP_TEST_MINIO_ENDPOINT.
        """
    end
  end
end
