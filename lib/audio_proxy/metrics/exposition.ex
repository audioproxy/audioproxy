defmodule AudioProxy.Metrics.Exposition do
  @moduledoc """
  The Prometheus text exposition format (version 0.0.4), as string assembly.

  `AudioProxy.Metrics` decides *what* the numbers are; this decides what they
  look like on the wire. The split is worth the extra module because the format
  has invariants a scraper enforces and a renderer can silently break — a
  histogram whose `+Inf` bucket disagrees with its `_count` is accepted by
  nothing and diagnosed by nobody — and those invariants are testable here
  against a hand-written series, with no telemetry, no ETS and no clock in the
  way.

  ## What the format requires, and what this does about it

  Every metric gets a `# HELP` and a `# TYPE` line, emitted whether or not it
  has samples: a scraper reading a fresh process should learn the metric exists
  and is a counter rather than infer both from the first sample to appear.

  Label values are escaped (`\\`, `"`, newline) and so is help text (`\\`,
  newline). Nothing in this application puts a quote in a label — every label
  value is a bounded enum — but escaping is one line and the alternative is a
  malformed scrape the day something does.

  Histograms are the part with real rules. Buckets are cumulative and emitted
  in ascending `le` order, `+Inf` last and equal to `_count`, with `_sum` in
  the metric's own unit. `AudioProxy.Metrics` counts observations into a single
  bucket each and the accumulation happens here, so a concurrent observation
  costs one `:ets.update_counter/4` rather than one per bucket edge.

  ## Determinism

  Series are sorted by their label values, so two scrapes of the same state
  produce byte-identical output. Prometheus does not require it; tests that
  assert on exact exposition do, and an operator diffing two scrapes by hand
  gets it for free.
  """

  @content_type "text/plain; version=0.0.4; charset=utf-8"

  @typedoc """
  One metric, as this module needs it.

  `labels` names the label keys in the order they are emitted; `help` is one
  sentence without a trailing newline.
  """
  @type definition :: %{
          required(:name) => String.t(),
          required(:type) => :counter | :gauge | :histogram,
          required(:help) => String.t(),
          optional(:labels) => [atom()],
          optional(:buckets) => [float()],
          optional(any()) => any()
        }

  @typedoc "A counter or gauge series: label values in definition order, and a number."
  @type sample :: {[String.t()], number()}

  @typedoc """
  A histogram series: label values, per-bucket observation counts in the
  definition's bucket order (one element longer than `buckets`, the last being
  the `+Inf` overflow), and the sum of the observations.
  """
  @type observation :: {[String.t()], %{buckets: [non_neg_integer()], sum: number()}}

  @doc "The `Content-Type` a scrape response must carry."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc """
  Renders `definitions` against `series`, a map of metric name to samples.

  A definition with no entry in `series` — or an empty one — still gets its
  `# HELP` and `# TYPE` lines.
  """
  @spec render([definition()], %{optional(String.t()) => [sample()] | [observation()]}) ::
          iodata()
  def render(definitions, series) do
    Enum.map(definitions, fn definition ->
      [
        "# HELP ",
        definition.name,
        " ",
        escape_help(definition.help),
        "\n# TYPE ",
        definition.name,
        " ",
        Atom.to_string(definition.type),
        "\n",
        samples(definition, Map.get(series, definition.name, []))
      ]
    end)
  end

  ## Samples

  defp samples(%{type: :histogram} = definition, observations) do
    observations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&histogram(definition, &1))
  end

  defp samples(definition, series) do
    series
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {values, value} ->
      [definition.name, labels(definition, values), " ", number(value), "\n"]
    end)
  end

  # `le` is a label like any other, so it is escaped and quoted like one — and
  # it goes last, after the metric's own labels, which is the convention every
  # exposition in the wild follows.
  defp histogram(definition, {values, %{buckets: counts, sum: sum}}) do
    edges = Enum.map(definition.buckets, &number/1) ++ ["+Inf"]

    {lines, total} =
      edges
      |> Enum.zip(counts)
      |> Enum.map_reduce(0, fn {edge, count}, cumulative ->
        cumulative = cumulative + count

        line = [
          definition.name,
          "_bucket",
          labels(definition, values, {"le", edge}),
          " ",
          Integer.to_string(cumulative),
          "\n"
        ]

        {line, cumulative}
      end)

    [
      lines,
      definition.name,
      "_sum",
      labels(definition, values),
      " ",
      number(sum),
      "\n",
      definition.name,
      "_count",
      labels(definition, values),
      " ",
      Integer.to_string(total),
      "\n"
    ]
  end

  ## Labels

  defp labels(definition, values, extra \\ nil) do
    pairs =
      definition
      |> Map.get(:labels, [])
      |> Enum.map(&Atom.to_string/1)
      |> Enum.zip(values)
      |> then(fn pairs -> if extra, do: pairs ++ [extra], else: pairs end)

    case pairs do
      [] ->
        []

      pairs ->
        [
          "{",
          pairs
          |> Enum.map(fn {key, value} -> [key, ~s(="), escape_label(value), ~s(")] end)
          |> Enum.intersperse(","),
          "}"
        ]
    end
  end

  ## Escaping and numbers

  defp escape_label(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
    |> String.replace("\n", "\\n")
  end

  # Quotes need no escaping in help text — it runs to the end of the line and
  # has no delimiter to close early.
  defp escape_help(help) do
    help
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
  end

  defp number(value) when is_integer(value), do: Integer.to_string(value)

  # `Float.to_string/1` is shortest-round-trip, so a bucket edge written `0.1`
  # here is the string `"0.1"` rather than `"0.10000000000000001"` — which
  # matters beyond looks: `le` is part of a series' identity, and a scraper
  # comparing it across scrapes is comparing the text.
  defp number(value) when is_float(value), do: Float.to_string(value)
end
