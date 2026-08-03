defmodule AudioProxy.S3.HttpClient do
  @moduledoc """
  `ex_aws`'s HTTP client behaviour, over OTP's `:httpc`.

  ## Why we own this

  `ex_aws` ships an adapter for `hackney` and requires `hackney ~> 4.0`, but
  the two do not fit: hackney 4.0 answers a bodyless response — every `HEAD`,
  every empty `404` — with a three-element `{:ok, status, headers}`, and
  `ExAws.Request.Hackney` matches only the four-element form. Every `head/2`
  in this proxy would raise `CaseClauseError` from inside the dependency.

  So an adapter had to be written whichever client we picked, and that
  settled which one: hackney would have brought twelve packages including a
  QUIC and WebTransport stack for a proxy that makes three kinds of S3 call,
  while `:httpc` is OTP's own and already in the release. `ex_aws`,
  `ex_aws_s3` and `sweet_xml` are the whole dependency cost.

  It is thirty lines against a two-function behaviour, and `ex_aws` treats the
  client as pluggable, so swapping back — to a fixed hackney, or to `req` when
  the HTTPS source backend wants one anyway — is a config change and this
  module.

  ## What `:httpc` needs handling for

  Charlists in, binaries out. A request with a body takes its content type as
  a *separate argument* rather than a header, and passing it in both places
  sends it twice. TLS verification is set explicitly because `:httpc`'s
  defaults have moved across OTP releases, and a client that signs every
  request and then talks to whoever answers is not worth the signing.
  """

  @behaviour ExAws.Request.HttpClient

  @default_timeout :timer.seconds(30)
  @default_connect_timeout :timer.seconds(5)

  # A profile of our own, not `:httpc`'s default. Two reasons: the default is
  # shared with anything else in the VM that uses `:httpc`, so its settings
  # are not ours to set; and it allows only two sessions per host, which would
  # throttle concurrent renders on the connection pool rather than on
  # `AP_MAX_CONCURRENCY`, the knob that is supposed to govern them.
  @profile :audio_proxy_s3

  @doc """
  Starts the dedicated `:httpc` profile and sizes its connection pool.

  Called once from `AudioProxy.Application.start/2`. Idempotent, so a restart
  of the supervision tree does not fail on an already-started profile.
  """
  @spec setup!(pos_integer()) :: :ok
  def setup!(max_sessions) do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Enough sessions for every render to have one in flight, plus headroom
    # for the HEADs that precede a read.
    :ok =
      :httpc.set_options(
        [max_sessions: max_sessions * 2, max_keep_alive_length: max_sessions * 2],
        @profile
      )
  end

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    request = build(method, String.to_charlist(url), body, headers)

    case :httpc.request(
           method,
           request,
           options(url, http_opts),
           [body_format: :binary],
           @profile
         ) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok,
         %{
           status_code: status,
           headers: normalize(response_headers),
           body: response_body
         }}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  # `:httpc` takes the content type out of band for methods that carry a
  # body, and adds the header itself from that argument.
  defp build(method, url, body, headers) when method in [:post, :put, :patch] do
    {content_type, rest} = extract_content_type(headers)

    {url, charlists(rest), String.to_charlist(content_type), body}
  end

  defp build(_method, url, _body, headers), do: {url, charlists(headers)}

  defp extract_content_type(headers) do
    case Enum.split_with(headers, fn {name, _value} ->
           String.downcase(to_string(name)) == "content-type"
         end) do
      {[{_name, value} | _duplicates], rest} -> {to_string(value), rest}
      {[], rest} -> {"application/octet-stream", rest}
    end
  end

  defp charlists(headers) do
    for {name, value} <- headers,
        do: {String.to_charlist(to_string(name)), String.to_charlist(to_string(value))}
  end

  defp normalize(headers) do
    for {name, value} <- headers, do: {List.to_string(name), List.to_string(value)}
  end

  defp options(url, http_opts) do
    base = [
      timeout: Keyword.get(http_opts, :recv_timeout, @default_timeout),
      connect_timeout: Keyword.get(http_opts, :connect_timeout, @default_connect_timeout),
      # A redirect would be followed without the signature covering the new
      # target, and S3 answers 307 for a bucket in another region — which is
      # a misconfiguration to report, not to paper over.
      autoredirect: false
    ]

    if String.starts_with?(url, "https://"), do: [{:ssl, ssl_options(url)} | base], else: base
  end

  @doc """
  The `:ssl` options for a request to `url`.

  Public so a test can assert on the trust store without a TLS handshake.
  """
  @spec ssl_options(String.t()) :: keyword()
  def ssl_options(url) do
    host = url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

    [
      verify: :verify_peer,
      # Deeper than the three a private CA usually needs: an AWS chain can be
      # longer, and a depth that is too small fails the handshake with an
      # error that looks nothing like "raise this number".
      depth: 5,
      server_name_indication: host,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ] ++ trust_store()
  end

  # `cacertfile` and `cacerts` are mutually exclusive in `:ssl` — passing both
  # is an error, not a merge — so exactly one is emitted. `AP_S3_CA_BUNDLE` is
  # validated as a readable file at boot; there is deliberately no way to turn
  # verification off, since a flag for that ends up set in production because
  # it made a staging error go away.
  defp trust_store do
    case AudioProxy.Config.get(:s3).ca_bundle do
      nil -> [cacerts: :public_key.cacerts_get()]
      path -> [cacertfile: String.to_charlist(path)]
    end
  end
end
