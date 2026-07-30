defmodule AudioProxy.Signature do
  @moduledoc """
  URL signature generation and verification (API doc §1).

  A signed URL carries its signature as the first path segment:

      /{signature}/{options}/{source}

  The signature is `base64url(HMAC-SHA256(key, salt ‖ rest-of-path))`, where
  rest-of-path is the exact byte sequence after the signature segment, leading
  `/` included. Output is unpadded base64url; verification accepts padded and
  unpadded input. Key and salt are the hex-decoded `AP_KEY`/`AP_SALT` values
  from `AudioProxy.Config`.

  `sign/3` is the reference signer — tests use it, and clients can mirror it.
  `verify/2` is the request-path gate: constant-time comparison, and the
  literal `insecure` segment accepted only when `AP_ALLOW_INSECURE` is set.
  """

  alias AudioProxy.Config

  @insecure_segment "insecure"

  # An HMAC-SHA256 is 32 bytes → 43 unpadded base64url characters, or 44 with
  # the single canonical trailing "=".
  @sig_chars_unpadded 43

  @typedoc "Verification failure reason. The only one callers ever get."
  @type error_reason :: :invalid_signature

  @doc """
  Signs `rest_of_path` with `key` and `salt`, returning unpadded base64url.

  `rest_of_path` is everything after the signature segment, leading `/`
  required — exactly what `verify/2` expects back. A path without the leading
  slash can never verify (the request gate always prepends it), so it is
  rejected here with a `FunctionClauseError` instead of producing an unusable
  signature.
  """
  @spec sign(binary(), binary(), binary()) :: String.t()
  def sign("/" <> _ = rest_of_path, key, salt)
      when is_binary(key) and is_binary(salt) do
    key |> mac(salt, rest_of_path) |> Base.url_encode64(padding: false)
  end

  @doc """
  Verifies `sig_segment` against `rest_of_path` using the configured key/salt.

  Returns `:ok` or `{:error, :invalid_signature}` — callers get no finer
  distinction, so a missing key, garbage base64url, and a wrong MAC are
  indistinguishable from the outside.

  The literal `insecure` segment passes only when `AP_ALLOW_INSECURE` is
  enabled; otherwise it is just another invalid signature. Comparison runs on
  the decoded MAC bytes via `Plug.Crypto.secure_compare/2` (constant-time).

  Verification is strict about canonicality: a signature is 43 unpadded
  base64url characters or the same 43 with one trailing `=`, and the decoded
  bytes must re-encode to exactly the supplied characters. Over-padded input
  and the four final-character variants that decode to the same bytes are
  rejected — a signature is non-malleable, with exactly two accepted
  spellings. (Canonicalization of the *path* itself — percent-encoding,
  option order — belongs to the options parser, not this layer.)
  """
  @spec verify(binary(), binary()) :: :ok | {:error, error_reason()}
  def verify(sig_segment, rest_of_path)
      when is_binary(sig_segment) and is_binary(rest_of_path) do
    config = Config.all()

    cond do
      sig_segment == @insecure_segment ->
        if config.allow_insecure, do: :ok, else: {:error, :invalid_signature}

      is_nil(config.key) or is_nil(config.salt) ->
        {:error, :invalid_signature}

      true ->
        expected = mac(config.key, config.salt, rest_of_path)

        case decode(sig_segment) do
          {:ok, provided} -> compare(provided, expected)
          :error -> {:error, :invalid_signature}
        end
    end
  end

  defp mac(key, salt, data), do: :crypto.mac(:hmac, :sha256, key, salt <> data)

  # Strict decode: 43 unpadded chars, or 44 with exactly one trailing "=";
  # the decoded MAC must re-encode to the supplied characters, which rejects
  # over-padding and non-canonical final characters (4 variants share the
  # same 32 bytes — see the tamper test). Anything else is not a signature.
  defp decode(segment) do
    with true <- byte_size(segment) in [@sig_chars_unpadded, @sig_chars_unpadded + 1],
         trimmed <- String.trim_trailing(segment, "="),
         true <- byte_size(trimmed) == @sig_chars_unpadded,
         {:ok, mac} <- Base.url_decode64(trimmed, padding: false),
         true <- Base.url_encode64(mac, padding: false) == trimmed do
      {:ok, mac}
    else
      _ -> :error
    end
  end

  # secure_compare/2 is constant-time over equal-length inputs and returns
  # false immediately on a length mismatch — which also rejects decoded
  # segments that aren't the 32 bytes of an HMAC-SHA256.
  defp compare(provided, expected) do
    if Plug.Crypto.secure_compare(provided, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
