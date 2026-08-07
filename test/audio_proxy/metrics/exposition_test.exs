defmodule AudioProxy.Metrics.ExpositionTest do
  @moduledoc """
  The text format, against hand-written series.

  No telemetry, no ETS and no clock: what is under test is whether a known set
  of numbers renders as something a scraper accepts, and mixing the two would
  mean a format bug and an aggregation bug are the same failing assertion.
  `AudioProxy.MetricsTest` covers the other direction.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Metrics.Exposition

  @counter %{
    name: "widgets_total",
    type: :counter,
    labels: [:kind],
    help: "Widgets, by kind."
  }

  @gauge %{name: "widgets_running", type: :gauge, help: "Widgets in flight."}

  @histogram %{
    name: "widget_seconds",
    type: :histogram,
    labels: [:kind],
    buckets: [0.1, 1.0],
    help: "Seconds per widget."
  }

  defp render(definitions, series) do
    definitions |> Exposition.render(series) |> IO.iodata_to_binary()
  end

  describe "metadata lines" do
    test "every metric gets HELP and TYPE, samples or not" do
      output = render([@counter, @gauge], %{})

      assert output == """
             # HELP widgets_total Widgets, by kind.
             # TYPE widgets_total counter
             # HELP widgets_running Widgets in flight.
             # TYPE widgets_running gauge
             """
    end

    test "backslashes and newlines in help text are escaped" do
      definition = %{@gauge | help: "A \\ and a\nbreak."}

      assert render([definition], %{}) =~ "# HELP widgets_running A \\\\ and a\\nbreak.\n"
    end
  end

  describe "counters and gauges" do
    test "labels are emitted in the definition's order" do
      series = %{"widgets_total" => [{["blue"], 3}]}

      assert render([@counter], series) =~ ~s(widgets_total{kind="blue"} 3\n)
    end

    test "an unlabeled metric has no brace" do
      assert render([@gauge], %{"widgets_running" => [{[], 2}]}) =~ "widgets_running 2\n"
    end

    test "series are sorted, so two scrapes of one state are byte-identical" do
      forwards = render([@counter], %{"widgets_total" => [{["a"], 1}, {["b"], 2}]})
      backwards = render([@counter], %{"widgets_total" => [{["b"], 2}, {["a"], 1}]})

      assert forwards == backwards
    end

    test "quotes, backslashes and newlines in a label value are escaped" do
      series = %{"widgets_total" => [{[~s(a"b\\c\nd)], 1}]}

      assert render([@counter], series) =~ ~s(widgets_total{kind="a\\"b\\\\c\\nd"} 1\n)
    end
  end

  describe "histograms" do
    test "buckets are cumulative, +Inf is last, and it equals the count" do
      series = %{"widget_seconds" => [{["blue"], %{buckets: [2, 3, 5], sum: 12.5}}]}

      assert render([@histogram], series) == """
             # HELP widget_seconds Seconds per widget.
             # TYPE widget_seconds histogram
             widget_seconds_bucket{kind="blue",le="0.1"} 2
             widget_seconds_bucket{kind="blue",le="1.0"} 5
             widget_seconds_bucket{kind="blue",le="+Inf"} 10
             widget_seconds_sum{kind="blue"} 12.5
             widget_seconds_count{kind="blue"} 10
             """
    end

    test "an empty histogram renders its metadata and nothing else" do
      assert render([@histogram], %{"widget_seconds" => []}) == """
             # HELP widget_seconds Seconds per widget.
             # TYPE widget_seconds histogram
             """
    end

    test "bucket edges render as the shortest float that round-trips" do
      definition = %{@histogram | buckets: [0.1, 0.25, 2.5]}
      series = %{"widget_seconds" => [{["blue"], %{buckets: [0, 0, 0, 0], sum: 0}}]}

      output = render([definition], series)

      # The point of pinning this: `le` is part of a series' identity, and a
      # scraper comparing it across scrapes is comparing the text.
      assert output =~ ~s(le="0.1")
      assert output =~ ~s(le="0.25")
      assert output =~ ~s(le="2.5")
      refute output =~ "0.10000"
    end
  end
end
