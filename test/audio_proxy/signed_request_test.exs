defmodule AudioProxy.SignedRequestTest do
  @moduledoc """
  The support module's own contract.

  Small, because the helper is small — but the three properties asserted here
  are the ones the eighteen files that depend on it cannot assert for
  themselves: that the floor really pins what it claims to, that an override
  wins over the floor rather than the other way round, and that a caller
  cannot silently forget the local root.
  """

  # `async: false`: the verify test below installs config, which is global.
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.{Signature, SignedRequest}

  describe "base_config/1" do
    test "pins every value the request chain reads" do
      config = SignedRequest.base_config(local_root: "/tmp/x")

      # The environment-independence floor. A boot-time AP_MAX_SRC_BYTES must
      # not be able to reach a test through any of these.
      assert config.key == SignedRequest.key()
      assert config.salt == SignedRequest.salt()
      assert config.allow_insecure == false
      assert config.max_src_bytes == 2_000_000_000
      assert config.max_variant_bytes == 2_000_000_000
      assert config.local_root == "/tmp/x"
    end

    test "an override wins over the floor" do
      # The merge direction is the whole ergonomic argument for the helper: a
      # file states the floor and its subject in one expression, and the
      # subject is what takes effect.
      config = SignedRequest.base_config(local_root: "/tmp/x", max_src_bytes: 10)

      assert config.max_src_bytes == 10
      assert config.max_variant_bytes == 2_000_000_000
    end

    test "carries overrides the floor says nothing about" do
      config = SignedRequest.base_config(local_root: "/tmp/x", probe_timeout: 1)

      assert config.probe_timeout == 1
    end

    test "a missing local root is a raise, not a default" do
      # Every caller has a per-test tmp dir, and a defaulted root would make
      # "which root do this file's sources resolve against" invisible.
      assert_raise ArgumentError, ~r/requires :local_root/, fn ->
        SignedRequest.base_config(probe_timeout: 1)
      end
    end

    test "takes a map as readily as a keyword list" do
      assert SignedRequest.base_config(%{local_root: "/tmp/x"}).local_root == "/tmp/x"
    end
  end

  describe "signed/1" do
    test "is the API doc §2 grammar: a signature over the remainder, then the remainder" do
      rest = "/f:opus/br:96/plain/local://piece.wav"

      signed = SignedRequest.signed(rest)

      assert signed ==
               "/" <> Signature.sign(rest, SignedRequest.key(), SignedRequest.salt()) <> rest

      assert String.ends_with?(signed, rest)
    end

    test "the path it builds is one the production verifier accepts" do
      # The point of keeping this an independent implementation: it is checked
      # against `Signature.verify/2` rather than derived from it, so the two
      # disagreeing is a failure here instead of an agreement by construction.
      rest = "/info/plain/local://piece.wav"

      put_config(%{
        key: SignedRequest.key(),
        salt: SignedRequest.salt(),
        allow_insecure: false
      })

      # The signature is the first segment; `rest` supplies its own leading
      # slash, so the split yields the empty string before it.
      ["", signature | _] = String.split(SignedRequest.signed(rest), "/")

      assert Signature.verify(signature, rest) == :ok
    end
  end

  describe "header/2" do
    test "is the first value, or nil when the header is absent" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_resp_header("x-audio-proxy", "HIT")

      assert SignedRequest.header(conn, "x-audio-proxy") == "HIT"
      assert SignedRequest.header(conn, "x-absent") == nil
    end
  end

  describe "conn/3" do
    test "folds the headers it is given into the request" do
      conn = SignedRequest.conn(:get, "/x", [{"range", "bytes=0-3"}])

      assert Plug.Conn.get_req_header(conn, "range") == ["bytes=0-3"]
      assert conn.method == "GET"
    end
  end
end
