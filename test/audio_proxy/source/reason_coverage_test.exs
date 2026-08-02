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

  test "every reason a remote type declares renders as the generic 404" do
    for type <- @remote_types, reason <- type.reasons() do
      assert reason in ErrorJSON.not_found_reasons(),
             "#{inspect(type)} can return #{inspect(reason)}, which ErrorJSON would answer 500 for"

      assert {404, [], _body} = ErrorJSON.render(reason)
    end
  end

  test "every declared reason has a message, so the list and the clauses cannot drift" do
    for type <- @remote_types, reason <- type.reasons() do
      assert is_binary(type.message(reason)),
             "#{inspect(type)} declares #{inspect(reason)} but has no message/1 clause for it"
    end
  end
end
