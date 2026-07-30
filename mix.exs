defmodule AudioProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :audio_proxy,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AudioProxy.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:stream_data, "~> 1.1", only: [:test]}
    ]
  end
end
