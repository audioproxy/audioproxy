defmodule AudioProxy.S3.HttpClientTest do
  @moduledoc """
  The TLS options the S3 client hands `:httpc`.

  Asserted rather than exercised through a handshake: standing up a private
  CA and a TLS listener would test `:ssl`, which works, instead of the one
  thing that is ours — which of `cacerts` and `cacertfile` gets passed, and
  that it is never both.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.S3.HttpClient

  @url "https://variants.example-store.test/abc/def.mp3"

  describe "ssl_options/1 trust store" do
    test "uses the system trust store by default" do
      put_bundle(nil)

      options = HttpClient.ssl_options(@url)

      assert is_list(options[:cacerts])
      refute Keyword.has_key?(options, :cacertfile)
    end

    @tag :tmp_dir
    test "uses the configured bundle instead when one is set", %{tmp_dir: tmp_dir} do
      bundle = Path.join(tmp_dir, "ca.pem")
      File.write!(bundle, "-----BEGIN CERTIFICATE-----\n")
      put_bundle(bundle)

      options = HttpClient.ssl_options(@url)

      assert options[:cacertfile] == String.to_charlist(bundle)

      # `:ssl` treats the two as mutually exclusive — passing both is an error,
      # not a merge — so this is the load-bearing half of the assertion.
      refute Keyword.has_key?(options, :cacerts)
    end

    @tag :tmp_dir
    test "verifies the peer either way", %{tmp_dir: tmp_dir} do
      # There is deliberately no `verify: :verify_none` to configure, so this
      # is the whole of it: whichever trust store is in play, the certificate
      # is checked against it.
      bundle = Path.join(tmp_dir, "ca.pem")
      File.write!(bundle, "-----BEGIN CERTIFICATE-----\n")

      for configured <- [nil, bundle] do
        put_bundle(configured)
        assert HttpClient.ssl_options(@url)[:verify] == :verify_peer
      end
    end

    test "checks the hostname against the URL's host" do
      put_bundle(nil)

      assert HttpClient.ssl_options(@url)[:server_name_indication] ==
               ~c"variants.example-store.test"
    end
  end

  defp put_bundle(bundle) do
    put_config(%{s3: %{AudioProxy.Config.get(:s3) | ca_bundle: bundle}})
    :ok
  end
end
