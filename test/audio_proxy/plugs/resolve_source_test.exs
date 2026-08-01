defmodule AudioProxy.Plugs.ResolveSourceTest do
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.Plugs.ResolveSource

  @moduletag tmp_dir: "resolve_source"

  @generic_404 %{"error" => "not_found", "message" => "Source not found"}

  setup %{tmp_dir: tmp_dir} do
    put_config(%{local_root: tmp_dir})
    :ok
  end

  defp call(source_string) do
    conn(:get, "/sig/f:mp3/#{source_string}")
    |> assign(:source_string, source_string)
    |> ResolveSource.call([])
  end

  describe "a servable source" do
    test "assigns the typed source" do
      conn = call("plain/local://previews/track.wav")

      refute conn.halted
      assert conn.assigns.source == {:local, "previews/track.wav"}
    end

    test "decodes escapes exactly once before assigning" do
      conn = call("plain/local://a%20track.wav")

      assert conn.assigns.source == {:local, "a track.wav"}
    end

    test "authorization is not existence — a missing file still resolves" do
      # Confinement is lexical: the file's absence is the action's stat/1 call,
      # not this plug's, so the 404 for "not there" stays byte-identical to
      # the 404 for "not allowed" without an oracle in between.
      conn = call("plain/local://missing.wav")

      refute conn.halted
      assert conn.assigns.source == {:local, "missing.wav"}
    end

    test "the enc/ form resolves to the same source as plain/" do
      conn = call("enc/" <> Base.url_encode64("local://previews/track.wav", padding: false))

      refute conn.halted
      assert conn.assigns.source == {:local, "previews/track.wav"}
    end
  end

  describe "failures, all the same generic 404" do
    test "a path climbing out of the root is not allowed" do
      conn = call("plain/local://../secret.wav")

      assert conn.halted
      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end

    test "an absolute path is not allowed" do
      assert call("plain/local:///etc/passwd").status == 404
    end

    test "an unknown scheme is not found" do
      conn = call("plain/s3://bucket/key.wav")

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end

    test "an unknown encoding is not found" do
      assert call("nonsense/x").status == 404
    end

    test "an invalid enc/ payload is not found" do
      assert call("enc/%%%not-base64%%%").status == 404
    end

    test "a malformed escape is not found" do
      assert call("plain/local://a%zztrack.wav").status == 404
    end
  end

  test "with no root configured, every local source is refused" do
    put_config(%{local_root: nil})

    conn = call("plain/local://previews/track.wav")

    assert conn.status == 404
    assert JSON.decode!(conn.resp_body) == @generic_404
  end
end
