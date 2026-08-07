defmodule AudioProxy.TelemetryTest do
  @moduledoc """
  The render event contract, exercised through a real render rather than by
  calling the emitters.

  This is the interface `add-metrics-endpoint` will attach an aggregator to,
  so what it pins is the shape a *consumer* sees: which events fire, in which
  order, and which measurement and metadata keys are on each. Nothing here
  asserts on log output — that is `AudioProxy.LogHandlerTest`'s job, and the
  point of the split is that the events are useful to something that does not
  log.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import ExUnit.CaptureLog
  import Plug.Test

  alias AudioProxy.Signature

  @moduletag tmp_dir: "telemetry"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])
  @payload_bytes 18

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")
    File.write!(Path.join(tmp_dir, "notaudio.txt"), "definitely not audio")

    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000,
      max_variant_bytes: 2_000_000_000
    })

    # `cache_status` is only meaningful against a known-empty registry: a
    # coordinator left lingering by another test would turn a `:miss` here
    # into a `:coalesced`.
    reset_coordinators()
    reset_probes()

    :ok
  end

  describe "a completed render" do
    test "fires start then stop with the documented measurements and metadata" do
      attach(:consumer)

      render("/f:opus/br:96/plain/local://piece.wav")

      assert_receive {:consumer, [:audio_proxy, :render, :start], start_measurements, start_meta}
      assert_receive {:consumer, [:audio_proxy, :render, :stop], stop_measurements, stop_meta}

      assert is_integer(start_measurements.system_time)

      assert start_meta == %{
               format: :opus,
               source: "local://piece.wav",
               cache_status: :miss
             }

      assert stop_measurements.bytes == @payload_bytes
      assert is_integer(stop_measurements.duration) and stop_measurements.duration >= 0

      assert stop_meta == %{
               format: :opus,
               source: "local://piece.wav",
               cache_status: :miss,
               outcome: :ok
             }
    end

    test "a request that attaches to a running render says so in its metadata" do
      attach(:consumer)

      # Sequential, and still coalesced: the finished coordinator stays
      # registered briefly, so the second request is served from its backlog.
      # Without `cache_status` that span reports the whole payload in
      # microseconds and reads as an impossibly fast encode.
      render("/f:opus/br:96/cb:coalesce/plain/local://piece.wav")
      render("/f:opus/br:96/cb:coalesce/plain/local://piece.wav")

      assert_receive {:consumer, [:audio_proxy, :render, :start], _, %{cache_status: :miss}}
      assert_receive {:consumer, [:audio_proxy, :render, :stop], _, %{cache_status: :miss}}

      assert_receive {:consumer, [:audio_proxy, :render, :start], _, %{cache_status: :coalesced}}

      assert_receive {:consumer, [:audio_proxy, :render, :stop], _,
                      %{cache_status: :coalesced, outcome: :ok}}
    end

    test "no exception event fires" do
      attach(:consumer)

      render("/f:mp3/plain/local://piece.wav")

      assert_receive {:consumer, [:audio_proxy, :render, :stop], _, _}
      refute_receive {:consumer, [:audio_proxy, :render, :exception], _, _}
    end
  end

  describe "a failed render" do
    test "fires start then exception carrying the failure class" do
      attach(:consumer)

      render("/f:mp3/plain/local://notaudio.txt")

      assert_receive {:consumer, [:audio_proxy, :render, :start], _, _}
      assert_receive {:consumer, [:audio_proxy, :render, :exception], measurements, meta}

      assert measurements.bytes == 0
      assert is_integer(measurements.duration)

      assert %{
               format: :mp3,
               source: "local://notaudio.txt",
               class: :undecodable,
               exit_status: 1,
               detail: detail
             } = meta

      assert detail =~ "Invalid data found when processing input"
    end

    test "no stop event fires — a render ends exactly one way" do
      attach(:consumer)

      render("/f:mp3/plain/local://notaudio.txt")

      assert_receive {:consumer, [:audio_proxy, :render, :exception], _, _}
      refute_receive {:consumer, [:audio_proxy, :render, :stop], _, _}
    end
  end

  describe "one instrumentation, two consumers" do
    test "a second handler sees identical data, with no change to the render path" do
      attach(:first)
      attach(:second)

      render("/f:mp3/plain/local://piece.wav")

      for event <- [:start, :stop] do
        name = [:audio_proxy, :render, event]

        assert_receive {:first, ^name, measurements, meta}
        assert_receive {:second, ^name, ^measurements, ^meta}
      end
    end
  end

  ## Helpers

  # Wrapped in `capture_log/1` because the boot-attached `AudioProxy.LogHandler`
  # is listening to these same events: a failed render here would otherwise put
  # its warning in the suite's output, where it reads as something going wrong.
  # What the handler *says* is `AudioProxy.LogHandlerTest`'s subject, not this
  # file's — here the log is a side effect to be swallowed.
  defp render(rest) do
    path = "/#{Signature.sign(rest, @key, @salt)}#{rest}"

    capture_log(fn -> conn(:get, path) |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts) end)
  end

  @doc false
  # A named function, not a closure: `:telemetry` logs a performance warning
  # for every locally-captured handler, and a test that shouts at its own
  # output is a test nobody reads.
  def forward(event, measurements, meta, {tag, pid}) do
    send(pid, {tag, event, measurements, meta})
  end

  # Forwards every render event to the test process under `tag`. Detached on
  # exit, so a handler cannot outlive the test that attached it.
  defp attach(tag) do
    id = {__MODULE__, tag, self()}

    :ok =
      :telemetry.attach_many(
        id,
        AudioProxy.Telemetry.render_events(),
        &__MODULE__.forward/4,
        {tag, self()}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
