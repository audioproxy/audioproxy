defmodule AudioProxy.Application do
  @moduledoc """
  OTP application entry point.

  Supervises the HTTP listener and nothing else — the app holds no state of its
  own; variants live in S3 and every request is fully described by its URL.
  """

  use Application

  require Logger

  @default_port 4000

  @impl true
  def start(_type, _args) do
    children = listener()

    Logger.info("audio_proxy #{vsn()} starting")

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioProxy.Supervisor)
  end

  # The test suite drives the router through Plug.Test, so it binds no socket.
  defp listener do
    if Application.get_env(:audio_proxy, :start_listener, true) do
      Logger.info("listening on http://0.0.0.0:#{port()}")
      [{Bandit, plug: AudioProxy.Router, scheme: :http, port: port()}]
    else
      []
    end
  end

  # The worktree workflow gives each branch its own hashed port via PORT.
  defp port do
    case System.get_env("PORT") do
      nil -> @default_port
      value -> String.to_integer(value)
    end
  end

  defp vsn, do: :audio_proxy |> Application.spec(:vsn) |> to_string()
end
