defmodule AudioProxy.SignatureTest do
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Signature

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  # Known-answer vectors, computed with an independent implementation so a
  # shared misunderstanding of the algorithm can't pass on both sides.
  # Generator (Python 3 stdlib):
  #
  #   import hmac, hashlib, base64
  #   key  = bytes.fromhex("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  #   salt = bytes.fromhex("FFEEDDCCBBAA99887766554433221100")
  #   path = b"/f:opus/br:96/plain/s3://masters/2026/piece-final.wav"
  #   base64.urlsafe_b64encode(hmac.new(key, salt + path, hashlib.sha256).digest()).rstrip(b"=")
  #
  #   # second vector: path = b"/info/plain/s3://b/k.wav"
  @path "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav"
  @sig "zfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns"
  @sig_padded "zfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns="

  @info_path "/info/plain/s3://b/k.wav"
  @info_sig "U6nyFdkSvjNo2mlBbJMGk1nwISbdcnEGlgKSWKBfKT4"

  setup do
    put_config(%{key: @key, salt: @salt, allow_insecure: false})
    :ok
  end

  describe "sign/3" do
    test "matches the known-answer vector" do
      assert Signature.sign(@path, @key, @salt) == @sig
      assert Signature.sign(@info_path, @key, @salt) == @info_sig
    end

    test "produces unpadded base64url" do
      sig = Signature.sign(@path, @key, @salt)

      refute String.ends_with?(sig, "=")
      assert sig =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "rejects a path without the leading slash it could never verify" do
      assert_raise FunctionClauseError, fn ->
        Signature.sign("f:opus/br:96/plain/s3://b/k.wav", @key, @salt)
      end
    end
  end

  describe "verify/2 with a valid signature" do
    test "accepts the known-answer vector" do
      assert Signature.verify(@sig, @path) == :ok
      assert Signature.verify(@info_sig, @info_path) == :ok
    end

    test "accepts the padded form of the same signature" do
      assert Signature.verify(@sig_padded, @path) == :ok
    end

    test "accepts what sign/3 produces" do
      path = "/f:aac/t:0:30/plain/s3://bucket/some key.wav"
      assert Signature.verify(Signature.sign(path, @key, @salt), path) == :ok
    end
  end

  describe "verify/2 with a tampered signature" do
    test "mutating any character fails" do
      # Strict canonicality makes every position significant: the last
      # character carries only 4 of its 6 bits, but its 3 non-canonical
      # variants are rejected by the re-encode check in decode/1.
      for index <- 0..(String.length(@sig) - 1) do
        mutated = mutate_at(@sig, index)

        assert Signature.verify(mutated, @path) == {:error, :invalid_signature},
               "mutation at index #{index} (#{mutated}) unexpectedly verified"
      end
    end

    test "all non-canonical last-character variants fail" do
      # The final character of a 43-char unpadded SHA-256 encoding has 4
      # significant bits, so 4 characters decode to the same 32 bytes; only
      # the canonical one may verify.
      variants = ~w(s t u v)
      assert String.ends_with?(@sig, "s")

      for last <- variants -- [String.last(@sig)] do
        mutated = String.slice(@sig, 0..-2//1) <> last

        assert Signature.verify(mutated, @path) == {:error, :invalid_signature},
               "non-canonical variant #{mutated} unexpectedly verified"
      end
    end

    test "over-padding is rejected while canonical padding is accepted" do
      assert Signature.verify(@sig <> "=", @path) == :ok
      assert Signature.verify(@sig <> "==", @path) == {:error, :invalid_signature}
      assert Signature.verify(@sig <> "===", @path) == {:error, :invalid_signature}
    end

    test "truncating or extending the signature fails" do
      assert Signature.verify(String.slice(@sig, 0..-2//1), @path) ==
               {:error, :invalid_signature}

      assert Signature.verify(@sig <> "AA", @path) == {:error, :invalid_signature}
    end
  end

  describe "verify/2 with a tampered path" do
    test "any changed segment after the signature fails" do
      for tampered <- [
            "/f:opus/br:128/plain/s3://masters/2026/piece-final.wav",
            "/f:opus/br:96/plain/s3://masters/2026/piece-final.waX",
            "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav ",
            "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav/extra",
            "f:opus/br:96/plain/s3://masters/2026/piece-final.wav"
          ] do
        assert Signature.verify(@sig, tampered) == {:error, :invalid_signature},
               "tampered path #{inspect(tampered)} unexpectedly verified"
      end
    end
  end

  describe "verify/2 with malformed input" do
    test "garbage base64url is rejected, not crashed on" do
      for garbage <- ["!!!", "not*base64", "a b c", "", "%20"] do
        assert Signature.verify(garbage, @path) == {:error, :invalid_signature}
      end
    end

    test "valid base64url of the wrong length is rejected" do
      assert Signature.verify(Base.url_encode64("too short", padding: false), @path) ==
               {:error, :invalid_signature}
    end
  end

  describe "verify/2 without configured credentials" do
    test "no key/salt means every signature fails" do
      put_config(%{key: nil, salt: nil})

      assert Signature.verify(@sig, @path) == {:error, :invalid_signature}
    end

    test "partial credentials mean every signature fails" do
      put_config(%{key: @key, salt: nil})
      assert Signature.verify(@sig, @path) == {:error, :invalid_signature}

      put_config(%{key: nil, salt: @salt})
      assert Signature.verify(@sig, @path) == {:error, :invalid_signature}
    end

    test "a signature valid under one key fails after key rotation" do
      other_key = :crypto.strong_rand_bytes(32)
      put_config(%{key: other_key})

      assert Signature.verify(@sig, @path) == {:error, :invalid_signature}
    end
  end

  describe "verify/2 edge shapes" do
    test "a rest-of-path of just / is verifiable when signed" do
      assert Signature.verify(Signature.sign("/", @key, @salt), "/") == :ok
    end

    test "non-UTF-8 bytes in the path round-trip" do
      path = "/plain/s3://b/" <> <<0xFF, 0xFE>> <> ".wav"

      assert Signature.verify(Signature.sign(path, @key, @salt), path) == :ok
    end
  end

  describe "insecure mode" do
    test "the literal insecure segment passes when AP_ALLOW_INSECURE is set" do
      put_config(%{allow_insecure: true})

      assert Signature.verify("insecure", @path) == :ok
    end

    test "the literal insecure segment fails by default" do
      assert Signature.verify("insecure", @path) == {:error, :invalid_signature}
    end

    test "insecure mode does not weaken real signatures" do
      put_config(%{allow_insecure: true})

      assert Signature.verify("yfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns", @path) ==
               {:error, :invalid_signature}
    end
  end

  defp mutate_at(string, index) do
    original = String.at(string, index)
    replacement = if original == "A", do: "B", else: "A"
    String.slice(string, 0, index) <> replacement <> String.slice(string, (index + 1)..-1//1)
  end
end
