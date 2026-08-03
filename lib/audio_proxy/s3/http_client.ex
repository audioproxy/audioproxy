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
  @connect_timeout :timer.seconds(5)

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    request = build(method, String.to_charlist(url), body, headers)

    case :httpc.request(method, request, options(url, http_opts), body_format: :binary) do
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
      connect_timeout: @connect_timeout,
      # A redirect would be followed without the signature covering the new
      # target, and S3 answers 307 for a bucket in another region — which is
      # a misconfiguration to report, not to paper over.
      autoredirect: false
    ]

    if String.starts_with?(url, "https://"), do: [{:ssl, ssl_options(url)} | base], else: base
  end

  defp ssl_options(url) do
    host = url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      server_name_indication: host,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  end
end
