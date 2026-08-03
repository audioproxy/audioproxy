defmodule AudioProxy.Peaks.Render do
  @moduledoc """
  A peaks render: probe, decode, reduce, serialize — behind
  `AudioProxy.Ffmpeg.Render`'s contract.

  `f:peaks` is a format, not a separate resource, so everything downstream of
  here is unchanged: `AudioProxy.RenderCoordinator` coalesces it, the
  write-back tee stores it, `AudioProxy.Plugs.RenderAction` streams it, and the
  next request for the same URL is a HIT. That only works because this process
  is indistinguishable from a render — same three messages, same `ack/2` cast,
  same `cancel/1` call, same "exactly one terminal message, then stop".

  ## Two subprocesses, one render

  A peaks render runs ffprobe and then ffmpeg, both as ordinary
  `AudioProxy.Ffmpeg.Render` children:

    1. **Probe.** `AudioProxy.Ffmpeg.Probe` asks for the duration and sample
       rate. Bucket boundaries are a function of the total sample count, and
       the alternative to knowing it up front is buffering the whole decode —
       memory instead of a header read. A probe is cheap and ranges rather
       than transfers.
    2. **Decode.** The argv `AudioProxy.Ffmpeg.Command` builds for `f:peaks`:
       raw interleaved `s16le` on stdout, trimmed and downmixed. Each chunk
       is folded into `AudioProxy.Peaks` and dropped; the PCM is never
       retained and never reaches the coordinator.

  Both inherit the pipeline's kill discipline and `AP_RENDER_TIMEOUT` — worth
  stating plainly, because that budget now covers two subprocesses in sequence
  rather than one. A probe that hangs is a `:timeout` classified exactly like
  a decode that hangs, and a source that 404s fails at the probe with
  `%{class: :not_found}`, which is the status the client would have got either
  way.

  ## One chunk, at the end

  The reduction is streaming, but the *output* is not: `pts` pairs are a few
  kilobytes and both serializations carry a header describing the whole body,
  so they are emitted as a single chunk followed by `{:done, _, _}`. That is
  why `ack/2` is accepted and ignored — there is no second chunk for a
  high-water mark to hold back.

  ## Failure

  Anything the two renders report is forwarded verbatim, so the classes the
  HTTP layer maps are the pipeline's own. What this module classifies itself is
  the probe's *output*, which ffprobe can write successfully while still
  describing something no waveform can be drawn from: a file with no audio
  stream, or one whose duration nothing can determine. Both are `:undecodable`,
  so both are a 415 — the source cannot yield this variant, permanently, and
  that is the client's business rather than a server fault to retry.

  Note what this is *not* claiming: `f:mp3` on the same file currently answers
  500, because ffmpeg's diagnostic there is "Output file does not contain any
  stream" and `AudioProxy.Ffmpeg.Render`'s classifiers do not match it. That
  gap is the audio path's and predates peaks; peaks answering 500 as well would
  have been consistency with a bug rather than with a contract.

  A probe this proxy could not *read* is different again and stays
  `:render_failed`: ffprobe exited cleanly and wrote something unparseable,
  which says nothing about the source and everything about the install.

  ## The request-side deadline is tighter here than for audio

  Worth knowing before tuning `AP_RENDER_TIMEOUT`.
  `AudioProxy.Plugs.RenderAction` bounds a render by a mailbox deadline of
  `AP_RENDER_TIMEOUT + 1s` that **restarts on every message**. For an audio
  render that is an idle timeout, because chunks arrive continuously, and the
  pipeline's own timer always fires first — which is what that module's
  moduledoc claims.

  Peaks send exactly one chunk, at the end, so nothing resets that clock
  between `{:rendering, _}` and completion: it is a *total* budget. Meanwhile
  each inner render gets a timer of its own, so the pipeline would tolerate up
  to twice the configured timeout across probe and decode. A peaks render
  taking longer than `AP_RENDER_TIMEOUT + 1s` is therefore ended by the request
  loop as a 504 with no ffmpeg diagnostic behind it, while neither subprocess
  considers itself late.

  At the 300 s default this needs a five-minute peaks render and no realistic
  source reaches it, which is why it is documented rather than designed around.
  Giving the two subprocesses one shared budget is the fix if it ever bites.
  """

  use GenServer

  alias AudioProxy.{Options, Peaks}
  alias AudioProxy.Ffmpeg.{Probe, Render, RenderSupervisor}

  @typedoc """
  What a peaks render needs beyond the decode argv.

    * `:options` — the parsed `t:AudioProxy.Options.t/0`, for `pts`, `ch` and
      the trim the probe's duration has to be narrowed by.
    * `:input` — what ffmpeg and ffprobe read; a presigned URL, usually.
    * `:probe_executable` — the ffprobe binary. Unset means `ffprobe` from
      `PATH`, which is what production uses; tests pass a stand-in.
  """
  @type spec :: keyword()

  defstruct [
    :consumer,
    :monitor,
    :options,
    :args,
    :executable,
    :inner,
    :inner_monitor,
    :reducer,
    phase: :probing,
    probe: []
  ]

  @doc """
  Starts a peaks render.

  Takes `AudioProxy.Ffmpeg.Render.start_link/1`'s options — `:args`,
  `:consumer`, `:executable` — plus the `:peaks` keyword list described in
  `t:spec/0`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    peaks = Keyword.fetch!(opts, :peaks)

    # Resolved before a process exists, for the reason `Render.start_link/1`
    # resolves ffmpeg there: a `{:stop, _}` from `init/1` exits an already
    # linked caller, and a missing binary is a plain error tuple instead.
    with {:ok, probe} <- Probe.executable(Keyword.get(peaks, :probe_executable)) do
      GenServer.start_link(__MODULE__, Keyword.put(opts, :probe_executable, probe))
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      # Above `Render.cancel_timeout/0`, which `terminate/2` can spend on the
      # inner render, for the reason `AudioProxy.RenderCoordinator` gives its
      # own budget the same margin.
      shutdown: Render.cancel_timeout() + 2_000
    }
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    peaks = Keyword.fetch!(opts, :peaks)
    consumer = Keyword.fetch!(opts, :consumer)

    state = %__MODULE__{
      consumer: consumer,
      monitor: Process.monitor(consumer),
      options: Keyword.fetch!(peaks, :options),
      args: Keyword.fetch!(opts, :args),
      executable: Keyword.get(opts, :executable),
      reducer: nil
    }

    # Both inner renders are children of the same `DynamicSupervisor` as this
    # process, and that supervisor is blocked inside `start_child/2` until
    # `init/1` returns — so spawning one from here would be this process asking
    # the supervisor that is waiting for it. The continuation runs after the
    # reply, which is the whole reason it exists here.
    {:ok, state,
     {:continue, {:probe, Keyword.fetch!(peaks, :input), Keyword.fetch!(opts, :probe_executable)}}}
  end

  @impl true
  def handle_continue({:probe, input, probe_executable}, state) do
    case start_inner(Probe.args(input), executable: probe_executable) do
      {:ok, inner} ->
        {:noreply, %{state | inner: inner, inner_monitor: Process.monitor(inner)}}

      {:error, reason} ->
        fail(state, %{
          class: :render_failed,
          exit_status: nil,
          stderr: "",
          detail: "could not start the peaks probe: #{inspect(reason)}"
        })
    end
  end

  # `Render.cancel/1` on this pid, which is what the coordinator calls.
  @impl true
  def handle_call(:cancel, _from, state) do
    send(state.consumer, {:error, self(), %{class: :cancelled, exit_status: nil, stderr: ""}})

    {:stop, :normal, :ok, state}
  end

  # `Render.ack/2` on this pid. Nothing to release — see *One chunk* above —
  # but it has to be accepted, because the coordinator acks every chunk it
  # gets and an unmatched cast would crash this process after the fact.
  @impl true
  def handle_cast({:ack, _bytes}, state), do: {:noreply, state}

  @impl true
  def handle_info({:chunk, inner, data}, %__MODULE__{inner: inner, phase: :probing} = state) do
    Render.ack(inner, byte_size(data))

    {:noreply, %{state | probe: [data | state.probe]}}
  end

  def handle_info({:chunk, inner, data}, %__MODULE__{inner: inner, phase: :decoding} = state) do
    Render.ack(inner, byte_size(data))

    {:noreply, %{state | reducer: Peaks.feed(state.reducer, data)}}
  end

  def handle_info({:done, inner, _info}, %__MODULE__{inner: inner, phase: :probing} = state) do
    forget_inner(state)

    case probed(state) do
      {:ok, state} -> start_decode(state)
      {:error, failure} -> fail(state, failure)
    end
  end

  def handle_info({:done, inner, _info}, %__MODULE__{inner: inner, phase: :decoding} = state) do
    forget_inner(state)

    payload =
      state.reducer
      |> Peaks.finish()
      |> Peaks.serialize(Options.peak_format(state.options))

    send(state.consumer, {:chunk, self(), payload})
    send(state.consumer, {:done, self(), %{exit_status: 0}})

    {:stop, :normal, %{state | inner: nil, inner_monitor: nil}}
  end

  # Whatever either subprocess said, said again with this process as the
  # handle. The class is the pipeline's, so a 404 source is a 404 whichever of
  # the two found it.
  def handle_info({:error, inner, failure}, %__MODULE__{inner: inner} = state) do
    forget_inner(state)
    fail(state, failure)
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %__MODULE__{inner_monitor: monitor} = state
      ) do
    fail(state, %{
      class: :render_failed,
      exit_status: nil,
      stderr: "",
      detail: "#{state.phase} render died without reporting: #{inspect(reason)}"
    })
  end

  # Nobody left to hand peaks to; `terminate/2` kills the subprocess.
  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %__MODULE__{monitor: monitor} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{inner: nil}), do: :ok

  def terminate(_reason, %__MODULE__{inner: inner}) do
    Render.cancel(inner)
    :ok
  end

  ## Phases

  defp start_inner(args, opts) do
    RenderSupervisor.start_render([args: args, consumer: self()] ++ compact(opts))
  end

  defp compact(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

  # The probe's stdout, read into the reducer the decode will fill. Everything
  # that can be wrong with it is wrong here, before a decode is spawned.
  defp probed(state) do
    with {:ok, info} <- Probe.parse(IO.iodata_to_binary(Enum.reverse(state.probe))),
         {:ok, duration} <- required_duration(info) do
      frames = round(region(duration, state.options) * info.sample_rate)

      {:ok, %{state | reducer: Peaks.new(frames, state.options, info.sample_rate)}}
    else
      {:error, reason} ->
        {:error,
         %{
           class: probe_class(reason),
           exit_status: nil,
           stderr: "",
           detail: "could not probe the source for peaks: #{inspect(reason)}"
         }}
    end
  end

  # A source with no audio stream, or one whose duration nothing can determine,
  # is a source peaks cannot be drawn from — permanently, and because of the
  # file rather than the server. That is a 415. See the moduledoc for why this
  # deliberately does not match what `f:mp3` currently answers for such a file.
  #
  # `:unreadable_probe` stays a server failure: ffprobe exited cleanly and
  # wrote something this proxy could not read, which says nothing about the
  # source and everything about the install.
  defp probe_class(:no_audio_stream), do: :undecodable
  defp probe_class(:unknown_duration), do: :undecodable
  defp probe_class(_reason), do: :render_failed

  defp required_duration(%{duration: nil}), do: {:error, :unknown_duration}
  defp required_duration(%{duration: duration}), do: {:ok, duration}

  # How much of the source the decode will actually produce, in seconds. The
  # trim is the same one the argv carries, applied to the probed duration; a
  # `t` that runs past the end of the source yields whatever is left, which is
  # what ffmpeg does too.
  defp region(duration, %Options{} = options) do
    remaining = max(duration - (options.trim_start || 0.0), 0.0)

    case options.trim_duration do
      nil -> remaining
      trim -> min(trim, remaining)
    end
  end

  defp start_decode(state) do
    case start_inner(state.args, executable: state.executable) do
      {:ok, inner} ->
        {:noreply,
         %{state | phase: :decoding, inner: inner, inner_monitor: Process.monitor(inner)}}

      {:error, reason} ->
        fail(state, %{
          class: :render_failed,
          exit_status: nil,
          stderr: "",
          detail: "could not start the peaks decode: #{inspect(reason)}"
        })
    end
  end

  defp fail(state, failure) do
    send(state.consumer, {:error, self(), failure})

    {:stop, :normal, %{state | inner: nil, inner_monitor: nil}}
  end

  # An inner render stops itself the moment it sends its terminal message, so
  # the monitor is flushed rather than waited on — leaving it would deliver a
  # `:DOWN` that the clause above would read as a render dying unreported.
  defp forget_inner(%__MODULE__{inner_monitor: nil}), do: :ok
  defp forget_inner(%__MODULE__{inner_monitor: monitor}), do: Process.demonitor(monitor, [:flush])
end
