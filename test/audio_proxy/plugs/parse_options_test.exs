defmodule AudioProxy.Plugs.ParseOptionsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AudioProxy.Options
  alias AudioProxy.Plugs.ParseOptions

  defp call(rest_of_path) do
    conn(:get, "/sig#{rest_of_path}")
    |> assign(:rest_of_path, rest_of_path)
    |> ParseOptions.call([])
  end

  describe "a well-formed path" do
    test "assigns the parsed options and the raw source string" do
      conn = call("/f:opus/br:96/plain/local://piece.wav")

      refute conn.halted
      assert %Options{format: :opus, bitrate: 96} = conn.assigns.options
      assert conn.assigns.source_string == "plain/local://piece.wav"
    end

    test "keeps the source string raw — escapes intact for the source parser" do
      conn = call("/f:mp3/plain/local://a%20track.wav")

      assert conn.assigns.source_string == "plain/local://a%20track.wav"
    end

    test "empty options parse to the defaults" do
      conn = call("/plain/local://piece.wav")

      refute conn.halted
      assert conn.assigns.options == %Options{}
      assert conn.assigns.source_string == "plain/local://piece.wav"
    end

    test "an option value that looks like a source marker does not split early" do
      conn = call("/dl:plain/f:mp3/plain/local://piece.wav")

      refute conn.halted
      assert %Options{download: "plain", format: :mp3} = conn.assigns.options
      assert conn.assigns.source_string == "plain/local://piece.wav"
    end

    test "the enc/ marker splits the same way plain/ does" do
      conn = call("/enc/bG9jYWw6Ly9waWVjZS53YXY")

      refute conn.halted
      assert conn.assigns.options == %Options{}
      assert conn.assigns.source_string == "enc/bG9jYWw6Ly9waWVjZS53YXY"
    end
  end

  describe "options failures" do
    test "an invalid option value is a 422 naming the segment" do
      conn = call("/f:bogus/plain/local://piece.wav")

      assert conn.halted
      assert conn.status == 422

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "invalid_options",
               "message" => ~s("f:bogus" is not a supported value)
             }
    end

    test "an unknown option key is a 422" do
      conn = call("/nope:1/plain/local://piece.wav")

      assert conn.status == 422
      assert JSON.decode!(conn.resp_body)["message"] =~ ~s("nope:1")
    end

    test "a cross-key conflict is a 422" do
      conn = call("/br:96/q:5/plain/local://piece.wav")

      assert conn.status == 422
    end

    test "an empty segment before the source is a 422, not silently dropped" do
      conn = call("//plain/local://piece.wav")

      assert conn.status == 422
      assert JSON.decode!(conn.resp_body)["message"] =~ "empty options segment"
    end
  end

  describe "a path with no source marker" do
    test "is the generic 404 — nothing servable is named" do
      conn = call("/f:mp3/br:96")

      assert conn.halted
      assert conn.status == 404

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "not_found",
               "message" => "Source not found"
             }
    end

    test "an empty rest-of-path (/{sig}/) is the same 404" do
      assert call("/").status == 404
    end
  end
end
