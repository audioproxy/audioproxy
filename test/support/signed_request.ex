defmodule AudioProxy.SignedRequest do
  @moduledoc """
  The signing preamble every endpoint test shares: key material, the config
  floor, and the construction of a signed path.

  **The key and salt here are fixed test vectors, not secrets.** They are
  never loaded by `lib/`, never read from the environment, and never an
  operational default — `AudioProxy.Config` takes `AP_KEY` and `AP_SALT` and
  has no fallback. They are literals in the suite so that a signature is
  reproducible across runs and machines, and they are in one file so a reader
  or a scanner meets them once.

  A test still calls `AudioProxy.ConfigHelper.put_config/1` itself. This module
  builds the map; it does not install it. That keeps the `async: false`
  requirement that `put_config/1` carries visible in every file that has it.

  The dependency on `AudioProxy.ConfigHelper` runs one way and is meant to:
  config is the lower layer, `base_config/1` is the signing layer stacked on
  top of `ConfigHelper.byte_limits/1`, and the byte limits therefore have one
  definition rather than two that a test could only report as drifted after the
  fact. Nothing in `ConfigHelper` knows this module exists.
  """

  alias AudioProxy.ConfigHelper
  alias AudioProxy.Signature

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @doc "The suite's signing key. See the moduledoc: a test vector, not a secret."
  @spec key() :: binary()
  def key, do: @key

  @doc "The suite's signing salt. See the moduledoc: a test vector, not a secret."
  @spec salt() :: binary()
  def salt, do: @salt

  @doc """
  The config floor an endpoint test needs, with `overrides` merged over it.

  Pin every config value the chain reads: a boot-time `AP_MAX_SRC_BYTES` in the
  environment must not be able to flip a test's 501s to 413s. Every caller
  depends on that and none of them says it, which is why the floor lives here
  rather than being copied into each `setup`.

  `local_root` is required and has no default. Every caller has a per-test tmp
  dir, and a helper that guessed one would make "which root does this file's
  sources resolve against" invisible in the file that cares about it. A file
  that signs nothing and resolves nothing wants
  `AudioProxy.ConfigHelper.byte_limits/1`, which this builds on, rather than a
  relaxation of that rule.

  Values a test is *about* belong in `overrides`, where a reader sees them:

      put_config(SignedRequest.base_config(local_root: tmp_dir, probe_timeout: 1))

  """
  @spec base_config(keyword() | map()) :: map()
  def base_config(overrides) do
    overrides = Map.new(overrides)

    unless Map.has_key?(overrides, :local_root) do
      raise ArgumentError,
            "AudioProxy.SignedRequest.base_config/1 requires :local_root — " <>
              "pass the test's tmp dir explicitly"
    end

    ConfigHelper.byte_limits()
    |> Map.merge(%{key: @key, salt: @salt, allow_insecure: false})
    |> Map.merge(overrides)
  end

  @doc """
  Turns a request remainder into a signed path.

  The grammar is `"/" <> signature <> rest`, where the signature covers `rest`
  exactly — including its leading slash and excluding nothing. That is the URL
  grammar from `docs/audio-proxy-api-v1.md` §2.

  This is deliberately an independent implementation of the grammar rather
  than a call into whatever `lib/` uses to *construct* signed paths. It shares
  only `Signature.sign/3`, the primitive under test elsewhere. If the suite's
  idea of the grammar and production's ever diverge, these tests fail — which
  is the point. A helper that called production path construction would agree
  with production by definition and prove nothing.
  """
  @spec signed(binary()) :: binary()
  def signed(rest), do: "/#{Signature.sign(rest, @key, @salt)}#{rest}"

  @doc """
  A `Plug.Test` conn for `method` and `path` with `headers` folded in as
  request headers.

  It builds the conn and stops. Which router the conn is then passed to stays
  at the call site, because that choice — the production `AudioProxy.Router`
  or a stand-in — is what a given test is about.

  Call it qualified, as `SignedRequest.conn/3`. A test file that imports this
  module alongside `Plug.Test` imports it `except: [conn: 3]`, because the two
  `conn`s would otherwise be ambiguous at every call site — including the bare
  `conn(:get, path)` that means `Plug.Test`'s. `headers` is therefore required
  rather than defaulted: with a default this would export a `conn/2` that
  collides with `Plug.Test.conn/2` as well.
  """
  @spec conn(atom(), binary(), [{binary(), binary()}]) :: Plug.Conn.t()
  def conn(method, path, headers) do
    Enum.reduce(headers, Plug.Test.conn(method, path), fn {k, v}, c ->
      Plug.Conn.put_req_header(c, k, v)
    end)
  end

  @doc """
  The first `name` response header, or `nil` when there is none.

  What this smooths over is `Plug.Conn.get_resp_header/2` returning a list. A
  caller that wants to assert *exactly one* of a header should use that list
  directly rather than this.
  """
  @spec header(Plug.Conn.t(), binary()) :: binary() | nil
  def header(conn, name) do
    case Plug.Conn.get_resp_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end
end
