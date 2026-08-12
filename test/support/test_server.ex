defmodule AudioProxy.TestServer do
  @moduledoc """
  The suite's one listener boot: start Bandit on an ephemeral loopback port
  under the test supervisor and hand back the port it actually got.

  Nine files needed a real socket — a raw HTTP client, a chunked response read
  off the wire, a stand-in S3 answering 503 — and each had written the same
  five lines. What those five lines really are is a coupling to two
  dependencies' internals, so this module exists to hold it once.

  ## `port: 0` and read-back is the technique, not the line

  The listener binds port zero and is then asked what it was given, rather than
  picking a free port in advance. Choosing in advance means bind-read-close,
  hand the number over, and hope nothing else took it in between — a race that
  a busy CI runner or two parallel worktrees will lose. `bin/check-capacity`
  reached the same conclusion on the operational side; the suite reached it
  independently and never wrote it down.

  ## `ThousandIsland.listener_info/1` is the upgrade-fragile line

  It is reached through Bandit's supervisor pid, and it is the one call here a
  dependency upgrade can change out from under the suite. It now fails in one
  place instead of nine: a `MatchError` raised from this module means *Bandit
  or Thousand Island changed how a bound port is reported*, not that the test
  calling it is broken.

  ## The loopback match is an assertion

  `{:ok, {{127, 0, 0, 1}, port}}` pins the bind address on both sides
  deliberately. It is a free check that the listener came up loopback-only, and
  relaxing it to `{_ip, port}` would silently accept one bound to every
  interface. It is a check, not leftover pattern.

  ## What it does not do

  It does not default the plug — which router a test mounts is that test's
  subject, so it is named at the call site — and it does not touch config.
  Every caller calls `put_config/1` before booting, with different values, and
  that ordering is load-bearing: the plug chain reads config per request, but
  it has to be right before the first one arrives.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  @type t :: %{port: :inet.port_number(), server: pid()}

  @doc """
  Starts `plug` under the test supervisor on an ephemeral loopback port.

  Returns `%{port: port, server: pid}` — six callers match `%{port: port}` and
  ignore the rest; the ones asserting on connections or on the bound address
  want the supervisor pid.

  `bandit_options` are merged over the defaults (`scheme: :http`,
  `ip: {127, 0, 0, 1}`, `port: 0`), so a test needing its own `http_options`
  extends rather than forks this. The one non-Bandit key it understands is
  `:id`, the child spec id, which defaults to one derived from the plug so that
  a file booting two listeners does not collide on `Bandit`.
  """
  @spec start!(module(), keyword()) :: t()
  def start!(plug, bandit_options \\ []) do
    {id, bandit_options} = Keyword.pop(bandit_options, :id, {__MODULE__, plug})

    options =
      Keyword.merge(
        [plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0],
        bandit_options
      )

    server = start_supervised!({Bandit, options}, id: id)

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    %{port: port, server: server}
  end
end
