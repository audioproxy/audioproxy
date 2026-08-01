defmodule AudioProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :audio_proxy,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AudioProxy.Application, []}
    ]
  end

  # The release is what the Docker image ships: ERTS is bundled (the runtime
  # stage has no Erlang installed), and `rel/env.sh.eex` turns distribution off.
  defp releases do
    [
      audio_proxy: [
        include_executables_for: [:unix],
        applications: [audio_proxy: :permanent]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:stream_data, "~> 1.1", only: [:test]}
    ]
  end
end
