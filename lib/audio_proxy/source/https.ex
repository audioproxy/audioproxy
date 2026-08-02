defmodule AudioProxy.Source.Https do
  @moduledoc """
  The `https://` source type: audio fetched from an origin over TLS.

  `https://media.example/track.wav` names a URL, and the host is the whole of
  the policy: it is matched against `AP_SOURCE_ALLOWLIST`
  (`AudioProxy.Source.Allowlist`), which is **deny-by-default** — unset means no
  HTTPS source works at all. A proxy that fetches arbitrary URLs is a
  server-side request forgery primitive pointed at whatever the container can
  reach, so an operator has to name the origins they trust before any of this
  runs. An allowlisted host is trusted by definition; that trust is theirs to
  grant.

  ## Refused at the grammar

  `http://` never reaches this module: the resolver dispatches on scheme, no
  type claims `http`, and the source is `{:error, :unknown_scheme}`. Userinfo is
  refused here. Neither is merely left unallowlisted, because both are wrong
  independent of which host they name — a cleartext fetch has no place in a
  source, and credentials in a URL end up in logs, in argv, and in a cache key.
  Keeping them out also keeps the allowlist a single-axis policy: host, and
  nothing else.

  ## Canonical identity

  Everything that is a second *spelling* of one resource folds away, because
  each surviving spelling would otherwise buy one object a second cache key:

    * scheme and host lowercased, and a trailing root dot stripped
      (`https://Media.Example./a` → `https://media.example/a`);
    * an IP literal rendered in its canonical form
      (`https://[0:0:0:0:0:0:0:1]/a` → `https://[::1]/a`);
    * an explicit `:443` dropped — it is the scheme's default;
    * an absent path rendered `/`;
    * an empty query dropped, and any fragment dropped outright (a fragment is
      never sent to an origin, so it cannot name a different object).

  Two things are deliberately **not** normalized, because folding them would be
  a guess about a server this proxy does not run:

    * **The URL's own percent-encoding.** `https://h/a%2Fb` and `https://h/a/b`
      are different objects on many origins, so collapsing that layer would
      hand two objects one cache key. The visible cost is that an
      already-escaped URL needs double escaping in the `plain/` form
      (`%2520`) — which is exactly what `enc/` exists for.
    * **Dot segments.** `https://h/a/../b` is left as written: only the origin
      knows whether it resolves them.

  IP literals normalize through `:inet.parse_strict_address/1` rather than the
  lenient parser, and that choice is a security boundary. The lenient parser
  accepts inet_aton shorthand, where `1.2` means 1.0.0.2 and `01.2.3.4` means
  1.2.3.4. Folding those would let an allowlist entry for `1.2.3.4` silently
  admit `01.2.3.4`; left as text they stay distinct subjects, and are refused
  unless an operator names them in that exact spelling.

  ## Limits

  A URL may be 2048 bytes and a host 253 — the de-facto interoperable URL
  maximum and DNS's own name limit. Both were chosen after measuring rather
  than assumed: `URI.new/1` is linear in input length here (0.026 ms for a
  4 KB URL, 0.51 ms for 80 KB, ~6 ns/byte), and so is
  `:inet.parse_strict_address/1`, so unlike `AudioProxy.Source.Local`'s caps —
  where `Path.safe_relative/2` is superlinear and the cap is a denial-of-service
  control — these are protocol bounds, refusing at the door what no origin
  would answer anyway.

  ## Status: no backend yet

  `stat/1` and `ffmpeg_input/1` answer `{:error, :no_backend}`. The origin
  client they need — a HEAD for size and ETag, and the rules for what ffmpeg may
  be handed — arrives with `add-https-source-backend`; until then an `https://`
  source parses, canonicalizes and authorizes but cannot be rendered. The gap is
  pinned by a test, so it is a failing assertion away from being forgotten
  rather than a crash in production.
  """

  @behaviour AudioProxy.Source.Type

  alias AudioProxy.Source.Allowlist

  @typedoc "An HTTPS source: its canonical URL, which is also its identity."
  @type t :: {:http, String.t()}

  # The de-facto interoperable URL maximum, and DNS's limit on a name. See the
  # moduledoc: protocol bounds, not a cost-curve control.
  @max_url_bytes 2048
  @max_host_bytes 253

  # The scheme's default, which is therefore never rendered.
  @default_port 443

  # A body that carries a scheme of its own. It cannot arrive through the
  # resolver, which strips exactly one, so this only catches a hand-built call —
  # but `URI.new/1` would read `http://media.example/x` as the host `http`, and
  # a security gate must not be handed that.
  @scheme_prefix_re ~r{^[A-Za-z][A-Za-z0-9+.\-]*://}

  @impl true
  def scheme, do: "https"

  @impl true
  def tag, do: :http

  @impl true
  def parse(body) when is_binary(body) do
    with :ok <- bounded(body),
         {:ok, uri} <- uri(body),
         :ok <- without_userinfo(uri),
         {:ok, host} <- host(uri) do
      {:ok, {:http, render(host, uri)}}
    end
  end

  @impl true
  def canonical({:http, url}) when is_binary(url), do: url

  @impl true
  def authorize({:http, url}) when is_binary(url) do
    # The URL is re-parsed rather than pattern-matched out of the tuple: a
    # caller that built one by hand must get a verdict, not a `URI.Error` out
    # of a security check. The host is matched bracketless, which is both what
    # `URI` yields and what the allowlist documents.
    case parse_url(url) do
      {:ok, %URI{host: host}} when is_binary(host) -> Allowlist.authorize(:host, normalize(host))
      _undetermined -> {:error, :not_allowed}
    end
  end

  def authorize(_source), do: {:error, :not_allowed}

  @impl true
  def stat(_source), do: {:error, :no_backend}

  @impl true
  def ffmpeg_input(_source), do: {:error, :no_backend}

  @doc """
  A short human-readable sentence for one of this type's own reasons.
  """
  @spec message(atom()) :: String.t()
  def message(:invalid_url), do: "https source is not a URL with a host"
  def message(:userinfo_not_allowed), do: "https source carries embedded credentials"
  def message(:source_too_long), do: "https source is longer than a URL may usefully be"
  def message(:no_backend), do: "https sources have no storage backend yet"

  ## Parsing

  defp bounded(body) do
    # The scheme the resolver stripped counts against the budget: it is part of
    # the URL this parses, and of the canonical string it produces.
    if byte_size(body) + byte_size("https://") > @max_url_bytes do
      {:error, :source_too_long}
    else
      :ok
    end
  end

  defp uri(body) do
    if Regex.match?(@scheme_prefix_re, body) do
      {:error, :invalid_url}
    else
      parse_url("https://" <> body)
    end
  end

  defp parse_url(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, :invalid_url}
    end
  end

  defp without_userinfo(%URI{userinfo: nil}), do: :ok
  defp without_userinfo(%URI{}), do: {:error, :userinfo_not_allowed}

  defp host(%URI{host: host}) when is_binary(host) and host != "" do
    if byte_size(host) > @max_host_bytes do
      {:error, :source_too_long}
    else
      {:ok, normalize(host)}
    end
  end

  # `https:///a.wav` parses with an empty host, and a URL with no origin names
  # nothing this proxy could fetch.
  defp host(%URI{}), do: {:error, :invalid_url}

  ## Normalization

  # The bracketless canonical host, which is both what the allowlist matches
  # and what `authority/1` brackets back up for the URL.
  defp normalize(host) do
    host |> String.downcase() |> String.replace_suffix(".", "") |> ip_literal()
  end

  # Strict parsing only. See the moduledoc: the lenient parser would fold
  # `01.2.3.4` onto `1.2.3.4` and let one allowlist entry admit both.
  defp ip_literal(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> address |> :inet.ntoa() |> List.to_string()
      {:error, _not_an_address} -> host
    end
  end

  defp render(host, %URI{port: port, path: path, query: query}) do
    "https://" <> authority(host, port) <> path(path) <> query(query)
  end

  # An IPv6 literal is the one host that has to be bracketed to be a URL again.
  defp authority(host, port) do
    if String.contains?(host, ":") do
      "[" <> host <> "]" <> port(port)
    else
      host <> port(port)
    end
  end

  defp port(@default_port), do: ""
  defp port(nil), do: ""
  defp port(port), do: ":" <> Integer.to_string(port)

  defp path(nil), do: "/"
  defp path(""), do: "/"
  defp path(path), do: path

  # An empty query is what a bare `?` leaves behind; it names the same resource
  # as no query at all. Any fragment is dropped by never being rendered — it is
  # not sent to an origin, so it cannot name a different object.
  defp query(nil), do: ""
  defp query(""), do: ""
  defp query(query), do: "?" <> query
end
