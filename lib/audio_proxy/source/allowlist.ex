defmodule AudioProxy.Source.Allowlist do
  @moduledoc """
  `AP_SOURCE_ALLOWLIST`: which buckets and hosts a remote source may name.

  One comma-separated list answers for both remote source types, because the
  question is the same one — *is this namespace ours?* — and the answer differs
  only in how a namespace is spelled. `AudioProxy.Source.S3` asks about a
  bucket, `AudioProxy.Source.Https` about a host, and neither owns the matcher.

  Local sources are not gated here: `AP_LOCAL_ROOT` is the whole allowlist for
  disk (`AudioProxy.Source.Local`).

  ## The default differs by type, and that is the design

  An unset (empty) allowlist accepts **S3** sources and rejects **HTTPS** ones.
  An S3 bucket the proxy has no credentials for is unreadable whatever this
  list says, so the credentials are already a gate; an HTTPS URL has no such
  backstop, and an ungated one is a server-side request forgery primitive
  pointed at whatever the container can reach. Deny-by-default is the only safe
  posture for a fetch, so HTTPS sources need the operator to name a host before
  any of them work.

  ## The wildcards are asymmetric, and the asymmetry is the security property

      previews-*           bucket: trailing-`*` prefix glob
      *.media.example      host:   leading-`*.` suffix glob, label-anchored
      *                    either: everything
      masters              either: exact

  A bucket namespace belongs to the operator: nobody else can create
  `previews-eu` in their account, so a prefix glob hands out nothing. A host
  namespace belongs to anyone with a registrar, which is why hosts get the
  mirror image. `cdn.*` is the footgun this forecloses — it reads as "our CDN"
  and would mean "any host starting `cdn.`", `cdn.evil.com` included. A `*`
  anywhere but its type's documented position matches **nothing** rather than
  matching loosely; a pattern that cannot be honoured exactly is not honoured
  approximately.

  The host glob is anchored to a label boundary, so `*.media.example` admits
  `media.example` and `cdn.media.example`, and refuses `media.example.evil.com`
  — a suffix match on raw bytes would accept it.

  Buckets match case-sensitively and hosts fold case, because that is what S3
  and DNS respectively do.

  An IP-literal host is matched **bracketless**: the pattern for
  `https://[::1]/…` is `::1`, since that is the form `URI` parses out and the
  form `AudioProxy.Source.Https` normalizes to. The canonical URL shows the
  brackets, so this is worth knowing — the mismatch would otherwise fail closed
  and silently.

  Hosts are matched as written, with no IDN or punycode conversion: an operator
  allowlisting an internationalized domain writes its punycode form.
  """

  alias AudioProxy.Config

  @typedoc "Which namespace a subject lives in, and therefore which glob applies."
  @type kind :: :bucket | :host

  @doc """
  Decides whether `subject` — an S3 bucket or an already-normalized host — is
  allowlisted.

  Returns a verdict for any input, including one a caller built by hand: this
  is a security gate, and a gate that raises is a gate that can be turned into
  a 500. Anything that is not a non-empty binary is refused rather than
  interpreted.
  """
  @spec authorize(kind(), term()) :: :ok | {:error, :not_allowed}
  def authorize(kind, subject) when kind in [:bucket, :host] and is_binary(subject) do
    case {Config.get(:source_allowlist), subject} do
      {_patterns, ""} -> {:error, :not_allowed}
      {[], _subject} -> unset_policy(kind)
      {patterns, subject} -> verdict(Enum.any?(patterns, &matches?(kind, &1, subject)))
    end
  end

  def authorize(_kind, _subject), do: {:error, :not_allowed}

  @doc """
  Whether one pattern admits one subject — `authorize/2` without the config
  read, which is what makes the grammar testable on its own.
  """
  @spec matches?(kind(), String.t(), String.t()) :: boolean()
  def matches?(_kind, "*", _subject), do: true

  # Config yields binaries, so this is unreachable from a request — but this
  # module's contract is that it answers rather than raises, and that has to
  # hold for the whole module, not just for `authorize/2`.
  def matches?(_kind, pattern, subject) when not is_binary(pattern) or not is_binary(subject),
    do: false

  def matches?(:bucket, pattern, bucket) do
    case String.split(pattern, "*") do
      # No `*` at all: an exact, case-sensitive name.
      [^pattern] -> pattern == bucket
      # Exactly one, in the trailing position: a prefix glob.
      [prefix, ""] -> prefix != "" and String.starts_with?(bucket, prefix)
      # Anywhere else, or more than one: not a pattern this grammar has.
      _elsewhere -> false
    end
  end

  def matches?(:host, pattern, host) do
    case normalize_pattern(pattern) do
      "*." <> suffix -> label_suffix?(suffix, host)
      exact -> not String.contains?(exact, "*") and exact == host
    end
  end

  # The subject arrives normalized (`AudioProxy.Source.Https` downcases and
  # strips the root dot before asking); the pattern is an operator's typing, so
  # it gets the same treatment here rather than being trusted to match it.
  defp normalize_pattern(pattern) do
    pattern |> String.downcase() |> String.replace_suffix(".", "")
  end

  # Anchored to a label boundary: the suffix itself, or anything ending in a
  # `.` followed by it. `media.example.evil.com` ends with neither.
  defp label_suffix?(suffix, host) do
    suffix != "" and not String.contains?(suffix, "*") and
      (host == suffix or String.ends_with?(host, "." <> suffix))
  end

  # See the moduledoc: bucket credentials are already a gate, an HTTPS fetch
  # has none.
  defp unset_policy(:bucket), do: :ok
  defp unset_policy(:host), do: {:error, :not_allowed}

  defp verdict(true), do: :ok
  defp verdict(false), do: {:error, :not_allowed}
end
