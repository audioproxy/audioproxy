defmodule AudioProxy.ReadyEndpointTest do
  @moduledoc """
  `/ready` over the router: the statuses, the body, and the one thing the
  endpoint exists to prove — that a node declining work still answers
  `/health` 200.

  Unlike `AudioProxy.ReadinessTest`, this drives the *application's* semaphore
  and latch, because the wiring between them is what is under test here.
  Both are global, so this module is `async: false` and every test leaves the
  queue empty and the latch recovered.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.Eventually
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.Semaphore

  @deadline 2_000
  @opts AudioProxy.Router.init([])

  describe "GET /ready" do
    test "answers 200 with the reading the verdict was drawn from" do
      put_config(%{ready_queue_threshold: 2, max_concurrency: 1, queue_size: 4})

      conn = request(:get, "/ready")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert %{"status" => "ready", "queued" => 0, "threshold" => 2} =
               JSON.decode!(conn.resp_body)
    end

    test "requires no signature and is never cached" do
      # Outside the signed URL space, like `/health` (API doc §2), and
      # `no-store` because a stored verdict is advice about a load level that
      # has since moved.
      conn = request(:get, "/ready")

      assert conn.status in [200, 503]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "answers 503 once the queue reaches the threshold, and 200 again after it drains" do
      put_config(%{ready_queue_threshold: 2, max_concurrency: 1, queue_size: 4})

      # One holder plus two waiters: depth 2, the threshold.
      [_holder, first, second] = for _ <- 1..3, do: start_requester()

      conn = request(:get, "/ready")

      assert conn.status == 503
      assert %{"status" => "not_ready", "queued" => 2} = JSON.decode!(conn.resp_body)

      # `/health` is liveness, and a busy node is alive. An orchestrator that
      # read this endpoint for routing would be restarting containers for
      # being popular.
      assert request(:get, "/health").status == 200

      # Recovery mark is `div(2, 2)`, so the queue has to empty to 1 or below.
      drop(first)
      drop(second)

      assert request(:get, "/ready").status == 200
    end

    test "a threshold of zero disables the check entirely" do
      put_config(%{ready_queue_threshold: 0, max_concurrency: 1, queue_size: 4})

      [_holder, first, second] = for _ <- 1..3, do: start_requester()

      assert request(:get, "/ready").status == 200

      drop(first)
      drop(second)
    end
  end

  describe "HEAD /ready" do
    test "answers the GET's status and headers, bodiless" do
      put_config(%{ready_queue_threshold: 2, max_concurrency: 1, queue_size: 4})

      conn = request(:head, "/ready")

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "matches the GET while tripped too, which is the status that matters" do
      # An orchestrator probing with HEAD has to see the 503, or the endpoint
      # is only correct for the case that needed no endpoint.
      put_config(%{ready_queue_threshold: 2, max_concurrency: 1, queue_size: 4})

      [_holder, first, second] = for _ <- 1..3, do: start_requester()

      conn = request(:head, "/ready")

      assert conn.status == 503
      assert conn.resp_body == ""
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      drop(first)
      drop(second)

      assert request(:head, "/ready").status == 200
    end
  end

  ## Helpers

  defp request(method, path), do: method |> conn(path) |> AudioProxy.Router.call(@opts)

  defp start_requester do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:requested, self(), Semaphore.request()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)

    assert_receive {:requested, ^pid, outcome}, @deadline
    assert outcome in [:granted, :queued]

    pid
  end

  # See `AudioProxy.ReadinessTest.drop/2` for why this polls rather than
  # waiting on a `DOWN`.
  defp drop(waiter) do
    before = Semaphore.stats().queued
    Process.exit(waiter, :kill)

    wait_until(fn -> Semaphore.stats().queued < before end, @deadline)
  end
end
