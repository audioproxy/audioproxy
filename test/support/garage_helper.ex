defmodule AudioProxy.MinioHelper do
  @moduledoc """
  Pointing the config at the store the `:minio` suite runs against, and making
  sure a bucket is there.

  Every function raises rather than skipping when the store is absent. A green
  run against nothing is a lie about coverage — see `test/test_helper.exs`.
  """

  import ExUnit.Assertions

  alias AudioProxy.{Config, ConfigHelper, S3}

  @doc "The endpoint the `:minio` suite talks to, defaulting to the devcontainer's."
  @spec endpoint() :: URI.t()
  def endpoint do
    URI.parse(System.get_env("AP_TEST_MINIO_ENDPOINT", "http://minio:3900"))
  end

  @doc """
  The access key id the test store boots with.

  **A fixed test value, not a secret.** The devcontainer, CI and
  `bin/smoke-image` start the store with it, and nothing in `lib/` reads it.
  Garage requires the `GK` + 24 hex format.
  """
  @spec access_key_id() :: String.t()
  def access_key_id, do: "GK000000000000000000000000"

  @doc "The secret paired with `access_key_id/0`. Same caveat: a fixed test value."
  @spec secret_access_key() :: String.t()
  def secret_access_key, do: String.duplicate("0", 64)

  @doc """
  Puts the store credentials into the config and proves the store is up.

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
            access_key_id: access_key_id(),
            secret_access_key: secret_access_key(),
            session_token: nil,
            endpoint: endpoint,
            # The store is reached by hostname and port, so `bucket.minio` would
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

  @doc """
  Raises unless something answers HTTP at `endpoint`.

  Uses `:httpc`, the stack `AudioProxy.S3.HttpClient` drives, so the probe
  exercises what the proxy uses, minus signing.
  """
  @spec ensure_reachable!(URI.t()) :: :ok
  def ensure_reachable!(endpoint) do
    # Any HTTP response means a store is listening. Stores refuse unsigned
    # requests, so the status carries no information. Ignoring it keeps the
    # probe provider-neutral (docs/s3-providers.md).
    url = URI.to_string(%{endpoint | path: "/"})

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [connect_timeout: 2_000, timeout: 5_000],
           []
         ) do
      {:ok, {{_version, _status, _reason}, _headers, _body}} ->
        :ok

      other ->
        raise """
        The S3 store is not reachable at #{URI.to_string(endpoint)} (#{inspect(other)}).

        These tests are tagged :minio and excluded by default; running them
        requires a store. See docs/development.md, or set
        AP_TEST_MINIO_ENDPOINT.
        """
    end
  end
end
