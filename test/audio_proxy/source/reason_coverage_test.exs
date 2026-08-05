defmodule AudioProxy.Source.ReasonCoverageTest do
  @moduledoc """
  The seam between a source type's rejections and the response they render.

  `AudioProxy.ErrorJSON` has no catch-all on purpose: a reason missing from its
  list raises `FunctionClauseError` and answers 500. That is the right failure
  mode only if something fails *first* — otherwise the mistake ships and a
  request discovers it. This is that something.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.ErrorJSON
  alias AudioProxy.Source.{Https, S3}

  @remote_types [S3, Https]

  # The reasons that are deliberately *not* the blind 404. Listed here rather
  # than inferred so that adding one is a decision someone made in a slice,
  # not a row that quietly stopped being a 404 — the property this file exists
  # to defend is that a source failure and a store outage stay distinguishable
  # in exactly one direction.
  @not_a_source_failure %{not_configured: 500, upstream_unavailable: 502}

  test "every reason a remote type declares has a row, so none can answer 500 by accident" do
    for type <- @remote_types, reason <- type.reasons() do
      case Map.fetch(@not_a_source_failure, reason) do
        {:ok, status} ->
          refute reason in ErrorJSON.not_found_reasons(),
                 "#{inspect(reason)} must stay distinguishable from a missing object"

          assert {^status, [], _body} = ErrorJSON.render(reason)

        :error ->
          assert reason in ErrorJSON.not_found_reasons(),
                 "#{inspect(type)} can return #{inspect(reason)}, which ErrorJSON would answer 500 for"

          assert {404, [], _body} = ErrorJSON.render(reason)
      end
    end
  end

  test "every declared reason has a message, so the list and the clauses cannot drift" do
    for type <- @remote_types, reason <- type.reasons() do
      assert is_binary(type.message(reason)),
             "#{inspect(type)} declares #{inspect(reason)} but has no message/1 clause for it"
    end
  end
end
