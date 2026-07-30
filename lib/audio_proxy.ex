defmodule AudioProxy do
  @moduledoc """
  An imgproxy-style on-the-fly audio transcoding proxy.

  Sources live in S3 (or any HTTP-reachable store); variants are rendered on
  demand by ffmpeg, streamed to the first requester, and written back to a
  variant bucket for cached, range-capable serving thereafter.

  `docs/audio-proxy-api-v1.md` is the source of truth for the URL grammar,
  processing options, cache-key rules, headers, and error codes.
  """
end
