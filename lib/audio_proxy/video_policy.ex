defmodule AudioProxy.VideoPolicy do
  @moduledoc """
  What the proxy does with a source that carries a genuine video stream.

  `AudioProxy.Ffprobe.has_video?/1` answers the *question* — is this video, or
  is it the cover art virtually every tagged mp3 carries — and that answer is
  the same either way. This module holds the *verdict* on it, and only the
  verdict: `:reject`, which is the 415 the proxy has always given, or
  `:extract`, which lets the render proceed and take the audio track.

  ## Why the verdict is a seam and the question is not

  Both verdicts want exactly the same machinery in front of them: one
  header-read probe, the `attached_pic` nuance, the still-image fallback, and
  the failure classes the probe already maps. Extraction differs from rejection
  in one bit of what happens *after* the probe, so that one bit is what moved
  behind a module. Nothing else about the gate is configurable, and widening
  this seam past a two-valued enum is how it stops being one — a policy picks
  between two behaviours this application fully defines and tests; it cannot
  invent a third.

  The seam has no producer here. `AudioProxy.VideoPolicy.Reject` is the default
  and no OSS code path selects anything else, so with nothing configured the
  gate is byte-identical to the one that preceded this module — pinned by the
  existing gate suite running unchanged rather than by a new assertion.

  ## App env, deliberately not `AP_`

  The knob is `Application.get_env(:audio_proxy, :video_policy)`, read at the
  call site, and it is deliberately *not* an `AP_`-prefixed environment
  variable like every other setting in `AudioProxy.Config`. The intended
  consumer is an embedding release — an application that depends on this one
  and owns its own application env — not an operator holding the published
  image. An `AP_VIDEO_POLICY` would hand every deployment a lever on a
  behaviour that is not part of what the image offers; a module name in app env
  is reachable only by someone compiling a release around this code, which is
  exactly the audience.

  ## Egress is a different layer, and it does not read this

  `:extract` changes what is *admitted*, never what is emitted. Every argv
  `AudioProxy.Ffmpeg.Command` builds carries `-vn -sn -dn` and its format
  vocabulary contains no video encoder, so the render is an audio-only encode
  under either verdict — the ingest policy cannot loosen the egress guarantee
  because it is never consulted about it. That independence is the reason the
  `attached_pic` exemption can afford to trust a flag from a file the requester
  may control: the layer underneath does not care what the flag said.

  ## Implementing one

      defmodule MyRelease.ExtractPolicy do
        @behaviour AudioProxy.VideoPolicy

        @impl true
        def verdict(_probe), do: :extract
      end

      config :audio_proxy, video_policy: MyRelease.ExtractPolicy

  `verdict/1` receives the decoded ffprobe JSON — the same map
  `AudioProxy.Ffprobe.contract/2` maps and `has_video?/1` answered `true` for —
  so a policy that wants to decide per source (by duration, by codec, by
  stream count) has everything the proxy knows about it.
  """

  require Logger

  alias AudioProxy.Ffprobe

  @typedoc """
  The closed verdict enum.

  `:reject` refuses the source as `:video_source`, which the HTTP layer renders
  as 415. `:extract` admits it, and the render takes its audio track.
  """
  @type verdict :: :reject | :extract

  @doc """
  The verdict for a probe that `AudioProxy.Ffprobe.has_video?/1` called video.

  Called for video-containing sources only, so an implementation may assume
  that much and does not have to re-derive it.
  """
  @callback verdict(probe :: map()) :: verdict()

  @default AudioProxy.VideoPolicy.Reject

  @doc """
  The gate: `:ok` for a source this proxy will read, `{:error, :video_source}`
  for one it refuses.

  Both call sites — the render action before it takes a render slot, the info
  action before it describes anything — go through here rather than pairing
  `has_video?/1` with a policy lookup themselves. The pairing is the invariant
  worth centralising: a policy is consulted about *video*, so an audio-only
  source can never reach one, and neither endpoint can drift into asking it
  about something else.

      iex> AudioProxy.VideoPolicy.admit(%{"streams" => [%{"codec_type" => "audio"}]})
      :ok

      iex> AudioProxy.VideoPolicy.admit(%{"streams" => [
      ...>   %{"codec_type" => "video", "codec_name" => "h264"}
      ...> ]})
      {:error, :video_source}
  """
  @spec admit(map()) :: :ok | {:error, :video_source}
  def admit(probe) when is_map(probe) do
    if Ffprobe.has_video?(probe) do
      case verdict(probe) do
        :extract -> :ok
        :reject -> {:error, :video_source}
      end
    else
      :ok
    end
  end

  @doc """
  Asks the configured policy what to do with a video-containing probe.

  Defaults to `AudioProxy.VideoPolicy.Reject`.

  **A bad answer and a bad policy are different failures, handled differently
  on purpose.** A module that implements the behaviour and returns something
  outside the enum is a *runtime* answer this cannot use: it refuses the source
  and says so in the log, because refusing is the direction the rest of this
  gate fails — see `AudioProxy.Ffprobe.has_video?/1` on why the asymmetry runs
  that way — and because one odd answer should not take a request down.

  A value that is not a module, or a module not exporting `verdict/1`, is a
  *configuration* error and raises. That is the call `AudioProxy.Config` already
  makes: malformed values raise "so a misconfigured container fails immediately
  instead of serving traffic with surprising defaults". A release that misspells
  its policy module has not asked for `:reject` — it has asked for something
  that does not exist, and substituting the default would hide a broken
  deployment behind behaviour that looks deliberate.
  """
  @spec verdict(map()) :: verdict()
  def verdict(probe) when is_map(probe) do
    policy = Application.get_env(:audio_proxy, :video_policy, @default)

    case policy.verdict(probe) do
      verdict when verdict in [:reject, :extract] ->
        verdict

      other ->
        Logger.error(
          "video policy #{inspect(policy)} answered #{inspect(other)}, " <>
            "which is not :reject or :extract; refusing the source"
        )

        :reject
    end
  end
end
