defmodule AudioProxy.Source.LocalTest do
  # The configured root lives in `:persistent_term`, which is global.
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Source
  alias AudioProxy.Source.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    File.mkdir_p!(Path.join(root, "previews"))
    File.write!(Path.join(root, "previews/track.wav"), "RIFFfake")

    put_config(%{local_root: root})

    # Where an escape would land if one got through.
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.wav"), "SECRET")

    %{root: root, outside: outside}
  end

  defp enc(source), do: "enc/" <> Base.url_encode64(source, padding: false)

  describe "parse/1" do
    test "yields a source carrying the path relative to the root" do
      assert Local.parse("previews/track.wav") == {:ok, {:local, "previews/track.wav"}}
    end

    test "keeps the path as written, since confinement is authorize/1's job" do
      assert Local.parse("../etc/passwd") == {:ok, {:local, "../etc/passwd"}}
      assert Local.authorize({:local, "../etc/passwd"}) == {:error, :not_allowed}
    end

    test "refuses an empty path" do
      assert Local.parse("") == {:error, :empty_path}
    end
  end

  describe "through the resolver" do
    test "the local form parses" do
      assert Source.parse("plain/local://previews/track.wav") ==
               {:ok, {:local, "previews/track.wav"}}
    end

    test "the scheme is matched case-insensitively" do
      assert Source.parse("plain/LOCAL://previews/track.wav") ==
               {:ok, {:local, "previews/track.wav"}}
    end

    test "both encodings yield the same source and the same canonical string" do
      source = "local://previews/a track.wav"

      assert {:ok, from_plain} = Source.parse("plain/" <> URI.encode(source))
      assert {:ok, from_enc} = Source.parse(enc(source))

      assert from_plain == from_enc
      assert Source.canonical(from_plain) == Source.canonical(from_enc)
      assert Source.canonical(from_plain) == source
    end

    test "an escaped traversal is decoded before it is judged, and then refused" do
      assert {:ok, source} = Source.parse("plain/local://%2E%2E/outside/secret.wav")
      assert Source.authorize(source) == {:error, :not_allowed}
    end

    test "a NUL byte never reaches the confinement check" do
      assert Source.parse(enc("local://previews/\0track.wav")) == {:error, :control_character}
    end
  end

  describe "canonical/1" do
    test "is the source spelled back out" do
      assert Local.canonical({:local, "previews/track.wav"}) == "local://previews/track.wav"
    end

    test "does not depend on the root, so a variant survives a redeployment", %{tmp_dir: tmp_dir} do
      source = {:local, "previews/track.wav"}
      under_first_root = Local.canonical(source)

      elsewhere = Path.join(tmp_dir, "elsewhere")
      File.mkdir_p!(elsewhere)
      put_config(%{local_root: elsewhere})

      assert Local.canonical(source) == under_first_root
    end
  end

  describe "authorize/1" do
    test "admits a path under the root" do
      assert Local.authorize({:local, "previews/track.wav"}) == :ok
    end

    test "admits a path whose file does not exist — that is stat's answer, not policy" do
      assert Local.authorize({:local, "previews/absent.wav"}) == :ok
    end

    test "refuses every local source when no root is configured" do
      put_config(%{local_root: nil})

      assert Local.authorize({:local, "previews/track.wav"}) == {:error, :not_allowed}
    end

    test "refuses a root that is not a directory", %{tmp_dir: tmp_dir} do
      put_config(%{local_root: Path.join(tmp_dir, "does-not-exist")})

      assert Local.authorize({:local, "previews/track.wav"}) == {:error, :not_allowed}
    end

    test "refuses traversal, absolute paths and the root itself" do
      for path <- [
            "..",
            "../outside/secret.wav",
            "previews/../../outside/secret.wav",
            "../../../../../../etc/passwd",
            "/etc/passwd",
            "/",
            ".",
            "previews/..",
            "previews/track.wav/../../",
            <<"previews/tr", 0, "ack.wav">>
          ] do
        assert Local.authorize({:local, path}) == {:error, :not_allowed},
               "expected #{inspect(path)} to be refused"
      end
    end

    test "admits interior dot segments that stay inside the root" do
      assert Local.authorize({:local, "previews/./track.wav"}) == :ok
      assert Local.authorize({:local, "previews/sub/../track.wav"}) == :ok
    end

    test "refuses a symlink pointing out of the root", %{root: root, outside: outside} do
      File.ln_s!(Path.join(outside, "secret.wav"), Path.join(root, "escape.wav"))

      assert Local.authorize({:local, "escape.wav"}) == {:error, :not_allowed}
    end

    test "refuses a path reached through a symlinked directory", %{root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "elsewhere"))

      assert Local.authorize({:local, "elsewhere/secret.wav"}) == {:error, :not_allowed}
    end

    test "admits a symlink that stays inside the root", %{root: root} do
      File.ln_s!("previews/track.wav", Path.join(root, "alias.wav"))

      assert Local.authorize({:local, "alias.wav"}) == :ok
    end

    test "refuses a symlink with an absolute target, even one inside the root",
         %{root: root} do
      File.ln_s!(Path.join(root, "previews/track.wav"), Path.join(root, "absolute.wav"))

      assert Local.authorize({:local, "absolute.wav"}) == {:error, :not_allowed}
    end

    test "refuses a symlink cycle rather than chasing it", %{root: root} do
      File.ln_s!(Path.join(root, "pong"), Path.join(root, "ping"))
      File.ln_s!(Path.join(root, "ping"), Path.join(root, "pong"))

      assert Local.authorize({:local, "ping"}) == {:error, :not_allowed}
    end

    test "refuses a source that is not a local source at all" do
      assert Local.authorize({:local, :not_a_path}) == {:error, :not_allowed}
    end
  end

  describe "stat/1" do
    test "reports size and ETag material for a regular file" do
      assert {:ok, %{size: 8, etag: etag}} = Local.stat({:local, "previews/track.wav"})
      assert is_binary(etag)
    end

    test "the ETag changes when the file does", %{root: root} do
      assert {:ok, %{etag: before}} = Local.stat({:local, "previews/track.wav"})

      File.write!(Path.join(root, "previews/track.wav"), "RIFFfake-and-longer")

      assert {:ok, %{etag: later}} = Local.stat({:local, "previews/track.wav"})
      refute later == before
    end

    test "reports a missing file as not found" do
      assert Local.stat({:local, "previews/absent.wav"}) == {:error, :not_found}
    end

    test "reports a directory as not found" do
      assert Local.stat({:local, "previews"}) == {:error, :not_found}
    end

    test "reports a FIFO as not found", %{root: root} do
      fifo = Path.join(root, "pipe.wav")
      {_output, 0} = System.cmd("mkfifo", [fifo])

      assert Local.stat({:local, "pipe.wav"}) == {:error, :not_found}
    end

    test "refuses to stat outside the root" do
      assert Local.stat({:local, "../outside/secret.wav"}) == {:error, :not_allowed}
    end

    test "reports the true size, leaving AP_MAX_SRC_BYTES to the caller", %{root: root} do
      File.write!(Path.join(root, "big.wav"), :binary.copy("x", 4096))

      assert {:ok, %{size: 4096}} = Local.stat({:local, "big.wav"})
    end
  end

  describe "ffmpeg_input/1" do
    test "is the resolved absolute path", %{root: root} do
      assert {:ok, input} = Local.ffmpeg_input({:local, "previews/track.wav"})

      assert input == Path.join(resolved(root), "previews/track.wav")
      assert File.regular?(input)
    end

    test "is the symlink's target for a link inside the root", %{root: root} do
      File.ln_s!("previews/track.wav", Path.join(root, "alias.wav"))

      assert Local.ffmpeg_input({:local, "alias.wav"}) ==
               {:ok, Path.join(resolved(root), "previews/track.wav")}
    end

    test "refuses a path outside the root" do
      assert Local.ffmpeg_input({:local, "../outside/secret.wav"}) == {:error, :not_allowed}
    end
  end

  describe "the storage seam" do
    test "the render flow's two questions are answerable through the resolver alone" do
      assert {:ok, source} = Source.parse("plain/local://previews/track.wav")

      assert Source.authorize(source) == :ok
      assert {:ok, %{size: size, etag: etag}} = Source.stat(source)
      assert {:ok, input} = Source.ffmpeg_input(source)

      assert is_integer(size) and is_binary(etag) and is_binary(input)
    end

    test "and a stub backend answers them in the same shapes, with no filesystem in sight" do
      types = [AudioProxy.FakeSourceType]

      assert {:ok, source} = Source.parse("plain/fake://previews/track.wav", types)

      assert Source.authorize(source, types) == :ok
      assert {:ok, %{size: size, etag: etag}} = Source.stat(source, types)
      assert {:ok, input} = Source.ffmpeg_input(source, types)

      assert is_integer(size) and is_binary(etag) and is_binary(input)
    end
  end

  # macOS hands out temporary directories below a symlinked `/var`, so the path
  # a test writes to and the path `ffmpeg_input/1` resolves to differ unless the
  # expectation is resolved too.
  defp resolved(path) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn
      "/", _acc -> "/"
      component, acc -> resolve_component(Path.join(acc, component))
    end)
  end

  defp resolve_component(candidate) do
    case File.read_link(candidate) do
      {:ok, target} -> target |> Path.expand(Path.dirname(candidate)) |> resolved()
      {:error, _} -> candidate
    end
  end
end
