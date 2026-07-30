defmodule AudioProxy.SignaturePropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Bitwise

  alias AudioProxy.Config
  alias AudioProxy.Signature

  # verify/2 reads key/salt from the global config, so each run swaps the
  # generated credentials in and the original config is restored on exit.
  setup do
    previous = Config.all()
    on_exit(fn -> Config.put_all(previous) end)
    :ok
  end

  property "verify(sign(path), path) == :ok for random key/salt/path" do
    check all(
            key <- binary(min_length: 1, max_length: 64),
            salt <- binary(min_length: 1, max_length: 64),
            path <- path()
          ) do
      put_credentials(key, salt)

      assert Signature.verify(Signature.sign(path, key, salt), path) == :ok
    end
  end

  property "verify(sign(path), path) == :ok for paths with arbitrary bytes" do
    # Real request paths carry bytes ≥ 0x80 and possibly invalid UTF-8; the
    # signed string is bytes, not text.
    check all(
            key <- binary(min_length: 1, max_length: 64),
            salt <- binary(min_length: 1, max_length: 64),
            body <- binary(min_length: 1, max_length: 64)
          ) do
      put_credentials(key, salt)
      path = "/" <> body

      assert Signature.verify(Signature.sign(path, key, salt), path) == :ok
    end
  end

  property "random 43-char base64url strings never verify" do
    check all(
            key <- binary(min_length: 1, max_length: 64),
            salt <- binary(min_length: 1, max_length: 64),
            path <- path(),
            prefix <- string(base64url_chars(), length: 42),
            last <- member_of(canonical_last_chars())
          ) do
      put_credentials(key, salt)
      sig = prefix <> last

      refute sig == Signature.sign(path, key, salt)
      assert Signature.verify(sig, path) == {:error, :invalid_signature}
    end
  end

  property "any single-byte path mutation fails verification" do
    check all(
            key <- binary(min_length: 1, max_length: 64),
            salt <- binary(min_length: 1, max_length: 64),
            {path, index} <- path_and_index()
          ) do
      put_credentials(key, salt)

      mutated = mutate_byte(path, index)

      assert Signature.verify(Signature.sign(path, key, salt), mutated) ==
               {:error, :invalid_signature}
    end
  end

  # A rest-of-path: leading "/" followed by URL-plausible characters.
  defp path do
    gen all(body <- string(url_chars(), min_length: 1, max_length: 128)) do
      "/" <> body
    end
  end

  defp path_and_index do
    bind(path(), fn path ->
      tuple({constant(path), integer(0..(byte_size(path) - 1))})
    end)
  end

  defp url_chars do
    Enum.concat([?a..?z, ?A..?Z, ?0..?9, ~c"/:.-_~%"])
  end

  defp base64url_chars do
    Enum.concat([?a..?z, ?A..?Z, ?0..?9, ~c"-_"])
  end

  # The final character of a 43-char encoding carries only 4 significant
  # bits; just these 16 (low 2 bits zero) are canonical. Constraining to them
  # makes every generated candidate pass decode/1's canonicality check, so
  # the property exercises the MAC comparison it advertises.
  defp canonical_last_chars do
    ~w(A E I M Q U Y c g k o s w 0 4 8)
  end

  # XOR with 0x01 always yields a different byte.
  defp mutate_byte(binary, index) do
    <<before::binary-size(^index), byte, rest::binary>> = binary
    <<before::binary-size(index), bxor(byte, 0x01), rest::binary>>
  end

  defp put_credentials(key, salt) do
    Config.all()
    |> Map.merge(%{key: key, salt: salt, allow_insecure: false})
    |> Config.put_all()
  end
end
