defmodule AudioProxy.ErrorJSONTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AudioProxy.{ErrorJSON, OptionError}

  # The module's own list, not a copy — a hand-written list here would drift
  # silently (second-opinion finding M-2). A source type added later extends
  # `not_found_reasons/0` in its slice, and these tests then cover it.
  @source_not_found ErrorJSON.not_found_reasons()

  defp decoded(error) do
    {status, headers, body} = ErrorJSON.render(error)
    {status, headers, JSON.decode!(body)}
  end

  describe "the §5 table, row by row" do
    test "401: invalid signature" do
      assert {401, [], body} = decoded(:invalid_signature)

      assert body == %{
               "error" => "invalid_signature",
               "message" => "Invalid or missing signature"
             }
    end

    test "404: source missing, whatever the reason" do
      for reason <- @source_not_found do
        assert {404, [], %{"error" => "not_found", "message" => "Source not found"}} =
                 decoded(reason),
               "expected #{inspect(reason)} to render the generic 404"
      end
    end

    test "413: source exceeds AP_MAX_SRC_BYTES" do
      assert {413, [], body} = decoded(:source_too_large)

      assert body == %{
               "error" => "source_too_large",
               "message" => "Source exceeds AP_MAX_SRC_BYTES"
             }
    end

    test "415: undecodable source (producer lands with add-render-endpoint)" do
      assert {415, [], body} = decoded(:undecodable_source)

      assert body == %{
               "error" => "undecodable_source",
               "message" => "Source format is not decodable"
             }
    end

    test "422: invalid options, message names the segment" do
      error = OptionError.new("f:bogus", :invalid_value)

      assert {422, [], body} = decoded(error)

      assert body == %{
               "error" => "invalid_options",
               "message" => ~s("f:bogus" is not a supported value)
             }
    end

    test "429: queue full carries Retry-After from the error (producer: add-render-semaphore)" do
      assert {429, headers, body} = decoded({:queue_full, 7})

      assert headers == [{"retry-after", "7"}]
      assert body == %{"error" => "queue_full", "message" => "Render queue is full"}
    end

    test "504: render timeout (producer lands with add-render-endpoint)" do
      assert {504, [], body} = decoded(:render_timeout)

      assert body == %{
               "error" => "render_timeout",
               "message" => "Render exceeded AP_RENDER_TIMEOUT"
             }
    end
  end

  describe "the 404 row is deliberately blind" do
    test "unauthorized and missing sources render byte-identical bodies" do
      assert ErrorJSON.render(:not_allowed) == ErrorJSON.render(:not_found)
    end

    test "every source failure renders byte-identical bodies" do
      bodies = Enum.map(@source_not_found, &ErrorJSON.render/1)

      assert Enum.uniq(bodies) == [ErrorJSON.render(:not_found)]
    end
  end

  describe "halt_with/2" do
    test "sends the rendered row and halts" do
      conn = conn(:get, "/") |> ErrorJSON.halt_with(:source_too_large)

      assert conn.halted
      assert conn.status == 413
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert JSON.decode!(conn.resp_body)["error"] == "source_too_large"
    end

    test "sets extra headers from the row" do
      conn = conn(:get, "/") |> ErrorJSON.halt_with({:queue_full, 3})

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["3"]
    end
  end

  describe "every error declares its cacheability" do
    # One end-to-end pass over every row `render/1` has: the sent response
    # carries exactly the Cache-Control the moduledoc table documents, so no
    # CDN negative-caching default ever decides retention.
    @rows [
      {:invalid_signature, "max-age=60"},
      {OptionError.new("f:bogus", :invalid_value), "max-age=60"},
      {:source_too_large, "max-age=10"},
      {:undecodable_source, "max-age=10"},
      {{:queue_full, 3}, "no-store"},
      {:render_failed, "no-store"},
      {:render_timeout, "no-store"}
    ]

    test "each row's response carries its documented Cache-Control" do
      for {error, expected} <- @rows do
        conn = conn(:get, "/") |> ErrorJSON.halt_with(error)

        assert get_resp_header(conn, "cache-control") == [expected],
               "expected #{inspect(error)} (#{conn.status}) to carry #{inspect(expected)}"
      end
    end

    test "every source failure carries the 404 row's max-age=10" do
      for reason <- @source_not_found do
        conn = conn(:get, "/") |> ErrorJSON.halt_with(reason)

        assert conn.status == 404
        assert get_resp_header(conn, "cache-control") == ["max-age=10"]
      end
    end

    test "cache_control/1 has no default row" do
      # An unlisted status is a programmer error, same philosophy as
      # `render/1`: crash the slice that introduced it, never answer a
      # plausible retention policy in production.
      assert_raise FunctionClauseError, fn -> ErrorJSON.cache_control(418) end
    end
  end
end
