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
      # `:inets` and `:ssl` are OTP's own, and are what
      # `AudioProxy.S3.HttpClient` talks to S3 over — listed so the release
      # bundles them, since a release ships only what it is told about.
      extra_applications: [:logger, :inets, :ssl],
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
      # Not a new dependency — Plug and Bandit already bring it in. Declared
      # because the render path now emits into it directly
      # (`AudioProxy.Telemetry`), and a direct use should be a direct dep.
      {:telemetry, "~> 1.0"},
      # S3 access. `ex_aws_s3` over `ex_aws`, with `sweet_xml` for S3's XML
      # responses. A deliberate exception to the stdlib-first dependency
      # policy, argued in CLAUDE.md: the alternative was ~2000 lines of
      # hand-rolled SigV4, multipart orchestration and a fake S3 to test it
      # against, all owned by us against a request contract AWS changes and
      # we do not control.
      #
      # `hackney` is deliberately absent even though `ex_aws` lists it: its
      # bundled adapter does not handle hackney 4.0's bodyless responses, so
      # an adapter was needed regardless — and `AudioProxy.S3.HttpClient`
      # over OTP's own `:httpc` costs three packages here instead of twelve.
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:stream_data, "~> 1.1", only: [:test]}
    ]
  end
end
