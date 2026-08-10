defmodule AudioProxy.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/audioproxy/audioproxy"

  def project do
    [
      app: :audio_proxy,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases(),
      name: "audio_proxy",
      source_url: @source_url,
      description: description(),
      package: package(),
      docs: docs()
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

  defp description do
    "On-the-fly audio transcoding proxy: renders variants (transcodes, " <>
      "trimmed previews, waveform peaks) from signed URLs, streams them while " <>
      "they encode, and caches them for range-capable serving."
  end

  # A curated allowlist rather than an exclude list: a hex release is
  # permanent, so the question worth answering at publish time is "is this
  # file meant to ship?" rather than "did we remember to exclude it?".
  # `test/`, `openspec/`, `examples/`, `Dockerfile` and `.github/` are absent
  # by construction, and CI asserts that (see the `hex-package` job).
  #
  # `llms.txt` and `llms-full.txt` are why the docs ship at all: an embedder
  # with `{:audio_proxy, "~> 0.x"}` finds the whole URL contract in
  # `deps/audio_proxy/`, at the version they actually depend on, instead of
  # having to work out which tag that is on GitHub.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/releases",
        "Container image" => "https://github.com/audioproxy/audioproxy/pkgs/container/audioproxy"
      },
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE",
        "VERSIONS.md",
        "llms.txt",
        "llms-full.txt",
        "docs"
      ]
    ]
  end

  # The extras are the package's *documentation*, which is a smaller set than
  # the package's files. Two rules decide what is on the list.
  #
  # `llms.txt` and `llms-full.txt` are here because the README — the front page,
  # via `main: "readme"` — links to them prominently. A relative link from an
  # extra to a file ex_doc was never given resolves to nothing, so leaving them
  # off published a front page whose two most-pointed-at links were dead.
  #
  # `docs/development.md` is deliberately *not* here, though it does ship in
  # the tarball. It is about working on this repository — worktrees,
  # devcontainers, the release procedure — which is not a question a package
  # consumer has, and every one of its links points at a `bin/` script or a
  # dotfile the package does not carry. Links out to repository-only paths are
  # absolute GitHub URLs for that same reason.
  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "docs/audio-proxy-api-v1.md",
        "docs/sources.md",
        "docs/s3-providers.md",
        "docs/rendering.md",
        "docs/ffmpeg-arguments.md",
        "docs/scaling.md",
        "docs/capacity.md",
        "llms.txt",
        "llms-full.txt",
        "VERSIONS.md",
        "LICENSE"
      ]
    ]
  end

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
      {:stream_data, "~> 1.1", only: [:test]},
      # Docs only. `runtime: false` and `only: :dev` keep it out of both the
      # release and a consumer's dependency tree, so the dependency policy is
      # untouched at runtime.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
