defmodule AudioProxy.Source.RemotePropertyTest do
  @moduledoc """
  The three claims the remote source forms exist to make, stated as properties.

  Each one is a cache-key or an allowlist claim, and both are the kind that
  hold for the examples someone thought of and fail for the one they did not:

    * every *spelling* of one HTTPS resource is one canonical string, or one
      object quietly wears several cache keys;
    * a leading-`*.` host entry admits the domain and its subdomains and
      nothing else — in particular not `{domain}.{attacker}`, which a suffix
      match on raw bytes would happily accept;
    * an S3 key survives both encodings whatever bytes it carries, or the two
      spellings of one source render two variants.

  Nothing here reads configuration, so it runs async: the allowlist grammar is
  exercised through `matches?/3`, which is the matcher without the config read.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AudioProxy.Source
  alias AudioProxy.Source.Allowlist

  # Name hosts, whose case and trailing root dot fold, paired with what they
  # fold onto; then the IP literals, whose spelling folds instead.
  @name_hosts ["media.example", "cdn.media.example", "h"]
  @ip_hosts [
    {"[0:0:0:0:0:0:0:1]", "[::1]"},
    {"[::1]", "[::1]"},
    {"[2001:0db8:0000:0000:0000:0000:0000:0001]", "[2001:db8::1]"},
    {"1.2.3.4", "1.2.3.4"}
  ]

  @paths ["/a.wav", "/2026/piece-final.wav", "/a%20b.wav", "/a%2Fb.wav", "/a/../b.wav"]

  property "every spelling of one https URL converges on one canonical string" do
    check all(
            {spelled, canonical} <- host_spelling(),
            path <- member_of(@paths),
            port <- member_of(["", ":443"]),
            query <- member_of(["", "?"]),
            fragment <- member_of(["", "#", "#section"])
          ) do
      url = "https://" <> spelled <> port <> path <> query <> fragment

      # Escaped whole, so the URL's *own* escaping survives the one decode the
      # plain form gets — the `%2F` in a path is part of the URL, not of the
      # segment carrying it.
      plain = "plain/" <> URI.encode(url, &URI.char_unreserved?/1)
      encoded = "enc/" <> Base.url_encode64(url, padding: false)

      assert {:ok, source} = Source.parse(plain), "expected #{url} to parse"
      assert Source.parse(encoded) == {:ok, source}
      assert Source.canonical(source) == "https://" <> canonical <> path
    end
  end

  property "a leading-*. entry admits the domain and its subdomains, and nothing else" do
    check all(
            labels <- list_of(label(), min_length: 2, max_length: 3),
            subdomain <- list_of(label(), min_length: 1, max_length: 2),
            attacker <- list_of(label(), min_length: 1, max_length: 2)
          ) do
      domain = Enum.join(labels, ".")
      pattern = "*." <> domain

      # The domain itself and anything below it.
      assert Allowlist.matches?(:host, pattern, domain)
      assert Allowlist.matches?(:host, pattern, Enum.join(subdomain ++ labels, "."))

      # The attack the anchor exists to refuse: the domain as a *prefix* of a
      # name someone else can register.
      refute Allowlist.matches?(:host, pattern, Enum.join(labels ++ attacker, "."))

      # And the anchor itself — a label that merely ends in the domain's bytes.
      refute Allowlist.matches?(:host, pattern, "x" <> domain)
    end
  end

  property "an s3 key round-trips through both encodings whatever bytes it carries" do
    check all(
            bucket <- bucket(),
            key <- key()
          ) do
      source = "s3://" <> bucket <> "/" <> key
      plain = "plain/" <> URI.encode(source, &URI.char_unreserved?/1)
      encoded = "enc/" <> Base.url_encode64(source, padding: false)

      assert Source.parse(plain) == {:ok, {:s3, bucket, key}}
      assert Source.parse(encoded) == {:ok, {:s3, bucket, key}}
      assert Source.canonical({:s3, bucket, key}) == source
    end
  end

  ## Generators

  defp host_spelling do
    one_of([
      bind(member_of(@name_hosts), fn host ->
        bind(random_case(host), fn cased ->
          bind(member_of(["", "."]), fn root_dot ->
            constant({cased <> root_dot, host})
          end)
        end)
      end),
      member_of(@ip_hosts)
    ])
  end

  defp random_case(host) do
    host
    |> String.graphemes()
    |> Enum.map(&member_of([String.upcase(&1), String.downcase(&1)]))
    |> fixed_list()
    |> map(&Enum.join/1)
  end

  defp label, do: string(?a..?z, min_length: 1, max_length: 4)

  defp bucket, do: string([?a..?z, ?0..?9, ?-], min_length: 1, max_length: 20)

  # Every reserved character a URL has, a literal `%`, a space, and `/` — the
  # ones that make a key a different key, and the ones an encoding could eat.
  defp key do
    string([?a..?z, ?A..?Z, ?0..?9] ++ ~c"?#[]@!$&'()*+,;=%/ .-_~", min_length: 1, max_length: 40)
  end
end
