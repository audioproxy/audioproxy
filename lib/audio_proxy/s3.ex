defmodule AudioProxy.S3 do
  @moduledoc """
  The five S3 operations this proxy needs, over `ex_aws_s3`.

  Not a general S3 client and not on the way to becoming one. An
  object-storage deployment needs exactly this much:

    * `presign_get/3` — a URL ffmpeg can read a source from, and a URL a
      client can be redirected to on a cache hit. Presigned because neither
      of them will send an `Authorization` header for us.
    * `head/2` — does this object exist, how big is it, what is its ETag.
      The `/info` and cache-hit paths.
    * `put_stream/4` — write a variant back, streaming, without knowing its
      length in advance (a render's output length is not known until it ends).
    * `get_stream/3` — read a variant back for proxy-mode serving.
    * `delete/2` — remove one object. Nothing on the request path deletes
      anything; this exists for `AudioProxy.Config`'s boot-time writability
      probe, which proves a variant bucket accepts writes by performing one
      and then taking it back. A probe that only wrote would leave a small
      object behind on every restart.

  ## Why a facade and not `ExAws.S3` at the call sites

  Three reasons, none of them dogma. Callers get `{:error, :not_found}`
  instead of `{:error, {:http_error, 404, _}}`, which is the vocabulary the
  rest of the codebase already speaks. Credentials come from
  `AudioProxy.Config` rather than `ex_aws`'s own resolution — see below. And
  the surface stays four functions wide, so "we only do these four things"
  is enforced rather than merely intended.

  ## Configuration is ours, not `ex_aws`'s

  `ex_aws` resolves credentials from application env, `AWS_*` variables, and
  on EC2 from IMDS, in an order it decides. This proxy validates its whole
  configuration once at boot and keeps it in one map, so every call here
  passes an explicit config override built from `AudioProxy.Config`. The
  effect worth naming: **there is no IMDS lookup**, so an EC2 instance role
  does not work and credentials must be supplied. That is a documented
  limitation (README), not an oversight, and the place to change it is
  `config/0` here.

  ## Addressing is configured, not inferred

  A request names its bucket in the host (`bucket.host/key`, virtual-hosted)
  or in the path (`host/bucket/key`, path-style). `AP_S3_ADDRESSING` picks,
  defaulting to virtual-hosted with no custom endpoint and path-style with
  one — AWS requires the former in regions launched after 2019, and every
  S3-compatible store this project documents is deployed on the latter.

  It is threaded into both places `ex_aws` reads it, which are not the same
  place: the request path takes it from the config map, `presigned_url/5`
  from its own options. See `sign_get/3`.

  ## Two profiles, and `:source` is the default

  Fetching a source and running the variant store are two jobs that a
  deployment may hand to different providers or different principals, so
  every function here takes the profile to run under as its **last**
  argument: `:source` (the default, the `AWS_*`/`AP_S3_*` group) or `:store`
  (that group with `AP_VARIANT_S3_*` overlaid). `AudioProxy.Config` builds
  both and documents the fallback; all this module does is pick one.

  Defaulting to `:source` rather than requiring the argument is deliberate:
  the store is the *small* side — one module and the boot probe — and every
  other caller is a source fetch, so an omitted profile is right far more
  often than it is wrong.

  ## Errors are data

  Every function returns `{:ok, _}` or `{:error, t:error/0}`. `:not_found`
  and `:access_denied` stay distinct: AWS answers 403 for a missing object
  when the caller cannot list the bucket, so they are genuinely ambiguous —
  but folding them would turn an expired credential into a permanent cache
  miss and re-render every request forever.
  """

  alias AudioProxy.Config

  require Logger

  @typedoc "A bucket name."
  @type bucket :: String.t()

  @typedoc """
  Which configuration profile an operation runs under.

  `:source` is the shared `AWS_*`/`AP_S3_*` group; `:store` is that group with
  the `AP_VARIANT_S3_*` overrides applied. See the moduledoc.
  """
  @type profile :: :source | :store

  @typedoc "An object key, as raw bytes — never percent-encoded."
  @type key :: String.t()

  @typedoc """
  What `head/2` reports.

  `metadata` holds the `x-amz-meta-*` headers with the prefix stripped and
  names lowercased, which is how the variant store round-trips its own
  response headers through an object.
  """
  @type object :: %{
          size: non_neg_integer(),
          etag: String.t() | nil,
          content_type: String.t() | nil,
          cache_control: String.t() | nil,
          metadata: %{optional(String.t()) => String.t()}
        }

  @typedoc """
  Why an S3 call failed.

    * `:not_found` — the object is not there (404).
    * `:access_denied` — credentials rejected (403). Distinct from
      `:not_found` on purpose; see the moduledoc.
    * `{:http, status, body}` — any other status.
    * `{:transport, reason}` — nothing came back.
    * `:not_configured` — no credentials. Refused here rather than passed to
      `ex_aws` as nils, which it reads as "not provided" and answers by
      walking its own provider chain — ending at an instance-role lookup
      against 169.254.169.254 that, on a host where that address is not
      routed, hangs rather than failing.
    * `:invalid_range` — `get_stream/3` only.
  """
  @type error ::
          :not_found
          | :access_denied
          | :not_configured
          | :invalid_range
          | {:http, non_neg_integer(), binary()}
          | {:transport, term()}

  # Read granularity for `get_stream/3`. `ex_aws_s3` has no in-memory
  # streaming GET — `download_file/4` streams to disk and `get_object/3`
  # returns the whole body — so a bounded read is a sequence of ranged GETs.
  # 1 MiB keeps the request count sane for a full-length variant while
  # bounding memory well below one.
  @read_chunk 1_048_576

  # S3's minimum for a non-final part. A stream that ends inside this goes as
  # one `PutObject` instead — see `buffer_first_part/1`.
  @part_size 5 * 1024 * 1024

  # Set when the chunk source unwinds itself, so its cleanup is not run twice.
  # See `resume_next/1`.
  @source_unwound :audio_proxy_s3_source_unwound

  @doc """
  A presigned GET URL for an object.

  Options: `:expires_in` (seconds, defaulting to `AP_PRESIGN_TTL`).
  """
  @spec presign_get(bucket(), key(), keyword(), profile()) ::
          {:ok, String.t()} | {:error, error()}
  def presign_get(bucket, key, opts \\ [], profile \\ :source) do
    if configured?(profile),
      do: sign_get(bucket, key, opts, profile),
      else: {:error, :not_configured}
  end

  defp sign_get(bucket, key, opts, profile) do
    expires_in = Keyword.get(opts, :expires_in, Config.get(:presign_ttl))

    overrides = config(profile)

    # `presigned_url/5` signs locally rather than issuing a request, so it
    # wants a built `%ExAws.Config{}` where the request path takes overrides.
    signing_config = ExAws.Config.new(:s3, overrides)

    # Addressing is read from the *options* here and from the *config map* on
    # the request path — two separate readers inside `ex_aws`. Both are
    # threaded from the one keyword list so they cannot drift: the host is
    # covered by the SigV4 signature, so a presigned URL addressed differently
    # from the request that signed it is not merely wrong, it is unverifiable.
    signing_opts = [expires_in: expires_in, virtual_host: overrides[:virtual_host]]

    case ExAws.S3.presigned_url(signing_config, :get, bucket, key, signing_opts) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc "Object existence, size, ETag and metadata."
  @spec head(bucket(), key(), profile()) :: {:ok, object()} | {:error, error()}
  def head(bucket, key, profile \\ :source) do
    if configured?(profile),
      do: head_object(bucket, key, profile),
      else: {:error, :not_configured}
  end

  defp head_object(bucket, key, profile) do
    bucket
    |> ExAws.S3.head_object(key)
    |> request(profile)
    |> case do
      {:ok, %{headers: headers}} -> {:ok, object(headers)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Uploads `chunks` — an enumerable of binaries of unknown total length.

  Options: `:content_type`, `:cache_control`, and `:metadata` (a map written
  as `x-amz-meta-*`).

  A stream that ends inside one part is a single `PutObject`; anything longer
  is a multipart upload, **aborted** on every failure path so a failed write
  leaves neither a partial object nor billable orphan parts.

  ## Why the multipart protocol is driven here rather than by `ExAws.S3.upload/4`

  Because `upload/4` does not abort. `ExAws.S3.Upload.perform/2` initiates,
  uploads its parts, and on a part error simply returns that error — the
  upload id goes out of scope and the initiated upload, with every part
  already sent, stays in the bucket. `ex_aws_s3` defines
  `abort_multipart_upload/3` and never calls it. Incomplete multipart uploads
  do not appear in a bucket listing and are billed until a lifecycle rule
  removes them, which makes this the one place in the S3 surface where
  trusting the library costs money quietly.

  `upload/4` has a second problem on the same path: it collects task results
  with `Enum.map(fn {:ok, val} -> val end)`, which has no clause for the
  `{:exit, reason}` a part-level timeout produces, so a slow part raises
  `FunctionClauseError` from inside the dependency instead of returning an
  error.

  So the four operations are sequenced here. Everything underneath —
  signing, request building, XML parsing, retries — is still `ex_aws`; what
  is ours is the guarantee that an upload which does not complete is aborted. Parts go up one at a time, which keeps the memory
  bound honest at one part plus one chunk and costs nothing worth having:
  the render produces bytes far slower than S3 accepts them.

  Operators should still set a lifecycle rule expiring incomplete multipart
  uploads. This code aborts on every path it can see; a hard kill of the VM
  is not one of them.
  """
  @spec put_stream(bucket(), key(), Enumerable.t(), keyword(), profile()) ::
          :ok | {:error, error() | term()}
  def put_stream(bucket, key, chunks, opts \\ [], profile \\ :source) do
    if configured?(profile) do
      write(bucket, key, chunks, opts, profile)
    else
      {:error, :not_configured}
    end
  end

  defp write(bucket, key, chunks, opts, profile) do
    case buffer_first_part(chunks) do
      {:whole, iodata} ->
        put_object(bucket, key, IO.iodata_to_binary(iodata), opts, profile)

      # The upload is initiated *before* the stream is composed, so there is
      # exactly one path on which the suspended source is abandoned without
      # ever being enumerated — and it halts it explicitly. Compose first and
      # a failed initiate would drop the continuation on the floor, leaving
      # the source's `after_fun` unrun and whatever it holds open leaked.
      {:streamed, buffered, continuation} ->
        case initiate(bucket, key, opts, profile) do
          {:ok, upload_id} ->
            buffered
            |> Stream.concat(resume(continuation))
            |> into_parts()
            |> multipart(bucket, key, upload_id, profile)

          {:error, reason} ->
            halt(continuation)
            {:error, reason}
        end
    end
  rescue
    # The chunk stream raising is the tee's signal that a render failed or was
    # cancelled. Reached only for a raise *before* the upload is initiated —
    # once it is, `multipart/4` owns the abort.
    exception -> {:error, exception}
  end

  @doc """
  Removes an object.

  A delete of a key that is not there is `:ok` — S3 answers 204 either way,
  and the caller wanted the object gone rather than an inventory of what was
  there first.
  """
  @spec delete(bucket(), key(), profile()) :: :ok | {:error, error()}
  def delete(bucket, key, profile \\ :source) do
    if configured?(profile),
      do: delete_object(bucket, key, profile),
      else: {:error, :not_configured}
  end

  defp delete_object(bucket, key, profile) do
    bucket
    |> ExAws.S3.delete_object(key)
    |> request(profile)
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Streams an object's bytes, or an inclusive byte range of them.

  Lazy and bounded-memory: a sequence of ranged GETs of `#{@read_chunk}`
  bytes, never the whole object at once. `ex_aws_s3` offers no in-memory
  streaming read, so this is assembled here — see `@read_chunk`.

  Only proxy-mode serving needs it. A redirect hands the client a presigned
  URL and the bytes never enter the BEAM at all, which is the default and the
  reason this costs more round trips than it might.
  """
  @spec get_stream(bucket(), key(), {non_neg_integer(), non_neg_integer()} | nil, profile()) ::
          {:ok, Enumerable.t()} | {:error, error()}
  def get_stream(bucket, key, range \\ nil, profile \\ :source) do
    with true <- configured?(profile) or {:error, :not_configured},
         {:ok, %{size: size}} <- head(bucket, key, profile),
         {:ok, slice} <- slice(range, size) do
      {:ok, stream_slice(bucket, key, slice, profile)}
    end
  end

  # The range is resolved against the object's actual size *before* any read,
  # because getting this wrong is not a clean failure: an unclamped `last`
  # past the end means the first GET returns fewer bytes than asked for, the
  # offset advances short of `last`, and the *second* GET starts past the end
  # and draws a 416 — raised from inside a stream whose caller has already
  # begun sending a 200.
  #
  # Semantics match `AudioProxy.VariantStore.Local`, which is what makes the
  # two backends interchangeable: a `last` past the end is truncated (RFC 9110
  # §14), a `first` at or past the end is invalid, and an inverted range is
  # invalid rather than silently empty.
  defp slice(nil, 0), do: {:ok, :empty}
  defp slice(nil, size), do: {:ok, {0, size - 1}}

  defp slice({first, last}, size)
       when is_integer(first) and is_integer(last) and
              first >= 0 and first <= last and first < size do
    {:ok, {first, min(last, size - 1)}}
  end

  defp slice(_range, _size), do: {:error, :invalid_range}

  ## Writing

  defp put_object(bucket, key, body, opts, profile) do
    bucket
    |> ExAws.S3.put_object(key, body, upload_opts(opts))
    |> request(profile)
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Initiate, then parts, then complete — and abort on anything that is not a
  # completion, including an exception, a `throw` or an `exit` from the chunk
  # stream. See the `put_stream/4` doc for why this is not `ExAws.S3.upload/4`.
  defp multipart(stream, bucket, key, upload_id, profile) do
    try do
      with {:ok, parts} <- upload_parts(bucket, key, upload_id, stream, profile),
           :ok <- complete(bucket, key, upload_id, parts, profile) do
        :ok
      else
        {:error, reason} ->
          abort(bucket, key, upload_id, profile)
          {:error, reason}
      end
    rescue
      # The chunk stream raising mid-upload: a render that failed or was
      # cancelled. This is the path that leaves orphaned parts if nobody
      # aborts, which is exactly what `ExAws.S3.upload/4` does not do.
      exception ->
        abort(bucket, key, upload_id, profile)
        {:error, exception}
    catch
      # `throw` and `exit` unwind past `rescue`, and `exit` is the realistic
      # one — a task timeout or a linked crash inside the chunk stream.
      # Aborted, then re-raised: the point is the cleanup, not swallowing a
      # shutdown something else initiated.
      kind, reason ->
        abort(bucket, key, upload_id, profile)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp initiate(bucket, key, opts, profile) do
    bucket
    |> ExAws.S3.initiate_multipart_upload(key, upload_opts(opts))
    |> request(profile)
    |> case do
      {:ok, %{body: %{upload_id: upload_id}}} when is_binary(upload_id) and upload_id != "" ->
        {:ok, upload_id}

      {:ok, _response} ->
        {:error, {:http, 200, "InitiateMultipartUpload response carried no UploadId"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Sequential on purpose: one part in flight keeps the memory bound at one
  # part plus one chunk, and a render never produces bytes faster than S3
  # accepts them.
  defp upload_parts(bucket, key, upload_id, stream, profile) do
    stream
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {part, number}, {:ok, parts} ->
      case upload_part(bucket, key, upload_id, number, part, profile) do
        {:ok, etag} -> {:cont, {:ok, [{number, etag} | parts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_part(bucket, key, upload_id, number, body, profile) do
    bucket
    |> ExAws.S3.upload_part(key, upload_id, number, body)
    |> request(profile)
    |> case do
      {:ok, %{headers: headers}} ->
        case Enum.find(headers, fn {name, _value} -> String.downcase(name) == "etag" end) do
          {_name, etag} -> {:ok, etag}
          # Completing without the ETag S3 gave us would be rejected, so this
          # fails here rather than building a completion body with a nil in it.
          nil -> {:error, {:http, 200, "UploadPart response carried no ETag"}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete(bucket, key, upload_id, parts, profile) do
    bucket
    |> ExAws.S3.complete_multipart_upload(key, upload_id, parts)
    |> request(profile)
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Best-effort by necessity: if the abort itself fails there is nothing left
  # to try, and the caller is already reporting a failure. Logged at warning
  # so an operator can find the orphan, since a bucket listing will not show
  # it.
  defp abort(bucket, key, upload_id, profile) do
    bucket
    |> ExAws.S3.abort_multipart_upload(key, upload_id)
    |> request(profile)
    |> case do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "s3: could not abort multipart upload, parts may be orphaned and billed " <>
            "(bucket=#{bucket} key=#{key} upload_id=#{upload_id} reason=#{inspect(reason)})"
        )

        :ok
    end
  end

  # Reads up to one part from `chunks` without committing to a strategy.
  #
  # This exists because `ExAws.S3.upload/4` *always* runs the multipart
  # protocol, and S3 rejects a multipart upload whose only part is under
  # 5 MiB with `EntityTooSmall` — so it cannot write a small object at all.
  # Previews, which are most of what this proxy renders, are all small
  # objects. A single `PutObject` is also one request instead of three.
  #
  # The enumerable is consumed with an explicit `Enumerable.reduce/3`
  # suspension rather than `Enum.take/2` so the tail is never re-enumerated:
  # `chunks` is a live render, and asking it to start over is not a thing it
  # can do.
  defp buffer_first_part(chunks) do
    case Enumerable.reduce(chunks, {:cont, {[], 0}}, &buffer_reducer/2) do
      # The stream ended inside one part: send it whole.
      {:done, {buffered, _size}} ->
        {:whole, Enum.reverse(buffered)}

      # There is more, so it is a genuine multipart upload. The pieces are
      # handed back uncomposed: the caller initiates first, and must halt the
      # continuation if it decides not to stream after all.
      {:suspended, {buffered, _size}, continuation} ->
        {:streamed, Enum.reverse(buffered), continuation}

      {:halted, {buffered, _size}} ->
        {:whole, Enum.reverse(buffered)}
    end
  end

  defp buffer_reducer(chunk, {buffered, size}) do
    buffered = [chunk | buffered]
    size = size + byte_size(chunk)

    if size >= @part_size do
      {:suspend, {buffered, size}}
    else
      {:cont, {buffered, size}}
    end
  end

  # `ExAws.S3.upload/4` uploads **one part per element** — it does no
  # regrouping of its own. Render chunks are far smaller than S3's 5 MiB
  # minimum, so handing it the raw stream produces a hundred undersized parts
  # and `EntityTooSmall` at completion. Grouping is therefore ours to do.
  #
  # Every part but the last is *exactly* `@part_size`, not merely at least it.
  # Flushing whatever the buffer held when it crossed the threshold would make
  # a part's size depend on where chunk boundaries happen to fall, and some
  # stores — Cloudflare R2 among them — reject a multipart upload whose parts
  # are not all the same size. A chunk straddling the boundary is split, and
  # its tail carried into the next part.
  #
  # Memory stays bounded at one part plus one chunk, which is the same bound
  # the buffering above already establishes: the accumulator is iodata and is
  # flattened once per part, not once per chunk.
  defp into_parts(stream) do
    Stream.transform(
      stream,
      fn -> {[], 0} end,
      fn chunk, {buffered, size} ->
        buffered = [buffered, chunk]
        size = size + byte_size(chunk)

        if size >= @part_size do
          split_parts(IO.iodata_to_binary(buffered), [])
        else
          {[], {buffered, size}}
        end
      end,
      fn
        # A zero-length tail is not emitted: S3 rejects an empty part, and the
        # parts already sent are the whole object.
        {_buffered, 0} -> {[], {[], 0}}
        {buffered, _size} -> {[IO.iodata_to_binary(buffered)], {[], 0}}
      end,
      fn _acc -> :ok end
    )
  end

  # Peels whole parts off the front of the buffer — more than one when a
  # single chunk is larger than a part — and hands the remainder back as the
  # accumulator for the next chunk.
  defp split_parts(<<part::binary-size(@part_size), rest::binary>>, parts) do
    split_parts(rest, [part | parts])
  end

  # The remainder is copied rather than carried as a sub-binary. Pattern
  # matching a binary yields a reference into the original, so holding the
  # 10 KiB tail of a 5 MiB buffer holds the whole 5 MiB until the next part
  # flushes — which would make the bound above two parts rather than one. One
  # memcpy of at most a chunk's worth of bytes buys the buffer back.
  defp split_parts(rest, parts) do
    rest = :binary.copy(rest)
    {Enum.reverse(parts), {[rest], byte_size(rest)}}
  end

  # Resuming with `{:halt, _}` is what lets the *source* clean up: a suspended
  # `Enumerable.reduce/3` leaves the enumerable open, and a
  # `Stream.resource/3` — which is what a render tee is — runs its `after_fun`
  # only when its own reduce finishes or is halted.
  defp halt(continuation), do: continuation.({:halt, {[], 0}})

  # One chunk per resumption. `into_parts/1` regroups them.
  #
  # The state is `{:live, continuation}` until the source reports it is
  # finished, then `{:done, nil}` — which is what tells `after_fun` whether
  # there is still something suspended to halt.
  defp resume(continuation) do
    Stream.resource(
      fn ->
        Process.delete(@source_unwound)
        {:live, continuation}
      end,
      &resume_next/1,
      &resume_cleanup/1
    )
  end

  defp resume_next({:done, _finished}), do: {:halt, {:done, nil}}

  defp resume_next({:live, continuation}) do
    case continuation.({:cont, {[], 0}}) do
      {:suspended, {buffered, _size}, next} -> {Enum.reverse(buffered), {:live, next}}
      {:done, {buffered, _size}} -> {Enum.reverse(buffered), {:done, nil}}
      {:halted, {buffered, _size}} -> {Enum.reverse(buffered), {:done, nil}}
    end
  catch
    # An exception, `throw` or `exit` raised *by the source* unwinds the
    # source's own `Stream.resource`, which means its `after_fun` has already
    # run. Recorded so `resume_cleanup/1` does not then halt it a second time
    # and run that cleanup twice — a double `Port.close/1` raises, and doing
    # it here would raise *during* unwinding and mask the original error.
    #
    # The process dictionary is the one place a flag can survive an unwind
    # without threading state the `Stream.resource` contract has nowhere to
    # put. This is single-process, single-upload scope, which is the narrow
    # case it is actually good for.
    kind, reason ->
      Process.put(@source_unwound, true)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Reached whether the stream ran out, was abandoned mid-upload, or the
  # reduction raised — `Stream.resource/3` guarantees the `after_fun` on all
  # three. The source is halted only when it is still suspended *and* did not
  # unwind itself, so its own cleanup runs exactly once on every path.
  defp resume_cleanup({:done, _finished}) do
    Process.delete(@source_unwound)
    :ok
  end

  defp resume_cleanup({:live, continuation}) do
    unwound? = Process.get(@source_unwound, false)
    Process.delete(@source_unwound)

    unless unwound?, do: halt(continuation)

    :ok
  end

  ## Reading

  # A zero-length object is a legitimate variant — a render can produce no
  # bytes — and has no satisfiable range, so it streams as nothing rather
  # than asking S3 for a byte that is not there.
  defp stream_slice(_bucket, _key, :empty, _profile), do: []

  # One ranged GET per chunk. `Stream.resource/3` is not needed — there is no
  # resource to release, only arithmetic — so this is a plain unfold.
  defp stream_slice(bucket, key, {first, last}, profile) do
    Stream.unfold(first, fn
      offset when offset > last ->
        nil

      offset ->
        chunk_last = min(offset + @read_chunk - 1, last)

        case get_range(bucket, key, offset, chunk_last, profile) do
          # A conforming store cannot answer a satisfiable range with nothing,
          # and `slice/2` has already established the range is satisfiable —
          # but advancing by zero would spin this unfold forever, so it ends
          # instead.
          {:ok, ""} ->
            nil

          {:ok, body} ->
            {body, offset + byte_size(body)}

          # Mid-stream, with a response already going out to the client, there
          # is nothing to return an error value *to*. Reachable only if the
          # object changed between the `head/2` above and this read.
          {:error, reason} ->
            raise "s3: read failed at byte #{offset}: #{inspect(reason)}"
        end
    end)
  end

  defp get_range(bucket, key, first, last, profile) do
    bucket
    |> ExAws.S3.get_object(key, range: "bytes=#{first}-#{last}")
    |> request(profile)
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Requests

  defp request(operation, profile) do
    case ExAws.request(operation, config(profile)) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  # `ex_aws`'s error shapes, in this codebase's vocabulary.
  #
  # A 404 is only a miss when it is the *object* that is missing. S3 answers
  # 404 for a missing bucket too, and reporting that as a cache miss would
  # make a misconfigured `AP_VARIANT_STORE` look like a permanently cold
  # cache: every request a miss, every miss a re-render, every write-back
  # failing silently. The distinction is in the error code, so it is read.
  defp translate({:http_error, 404, %{body: body}}) when is_binary(body) do
    if String.contains?(body, "<Code>NoSuchBucket</Code>") do
      {:http, 404, body}
    else
      :not_found
    end
  end

  defp translate({:http_error, 404, _response}), do: :not_found
  defp translate({:http_error, 403, _response}), do: :access_denied

  defp translate({:http_error, status, %{body: body}}) when is_binary(body),
    do: {:http, status, body}

  defp translate({:http_error, status, _response}), do: {:http, status, ""}
  defp translate(reason), do: {:transport, reason}

  defp upload_opts(opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)

    Enum.reject(
      [
        content_type: opts[:content_type],
        cache_control: opts[:cache_control],
        meta: if(metadata == [], do: nil, else: metadata)
      ],
      fn {_name, value} -> is_nil(value) end
    )
  end

  defp object(headers) do
    headers = for {name, value} <- headers, into: %{}, do: {String.downcase(name), value}

    %{
      size: headers |> Map.get("content-length") |> to_integer(),
      etag: Map.get(headers, "etag"),
      content_type: Map.get(headers, "content-type"),
      cache_control: Map.get(headers, "cache-control"),
      metadata: user_metadata(headers)
    }
  end

  defp user_metadata(headers) do
    for {"x-amz-meta-" <> name, value} <- headers,
        into: %{},
        do: {String.downcase(name), value}
  end

  defp to_integer(nil), do: 0

  defp to_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  ## Configuration

  @doc """
  Reports whether credentials are configured.

  Checked before every operation, because `ex_aws` treats a nil credential as
  "not provided" rather than as an error — see `t:error/0`.
  """
  @spec configured?(profile()) :: boolean()
  def configured?(profile \\ :source), do: profile_config(profile).access_key_id != nil

  @doc """
  The `ex_aws` config overrides for one profile of this deployment.

  Public so a test can assert on the addressing decision without issuing a
  request.
  """

  @spec config(profile()) :: keyword()
  def config(profile \\ :source) do
    s3 = profile_config(profile)

    [
      access_key_id: s3.access_key_id,
      secret_access_key: s3.secret_access_key,
      region: s3.region,
      # `ex_aws` defaults to Jason, which this project does not depend on —
      # it uses OTP/Elixir's own `JSON`. Only reached when `ex_aws` decodes
      # an error body, which is exactly when a missing module would be most
      # confusing: the real failure disappears behind an UndefinedFunctionError.
      json_codec: JSON,
      # Ours rather than `ex_aws`'s bundled hackney adapter, which cannot
      # read hackney 4.0's bodyless responses. See `AudioProxy.S3.HttpClient`.
      http_client: AudioProxy.S3.HttpClient,
      # Read by `ExAws.Operation.S3`'s `add_bucket_to_path/2` on the request
      # path, and passed to `presigned_url/5` by `sign_get/3` — see there for
      # why the two must agree.
      virtual_host: s3.addressing == :virtual
    ] ++ security_token(s3.session_token) ++ endpoint(s3.endpoint)
  end

  # The one place the two profiles are told apart. Everything above takes a
  # profile only to hand it here.
  defp profile_config(:source), do: Config.get(:s3)
  defp profile_config(:store), do: Config.get(:variant_s3)

  # Omitted entirely rather than passed as `nil`: `ex_aws` sends the header
  # whenever the key is present, and a store reads an empty security token as
  # an invalid one — which fails every request with a message about temporary
  # credentials nobody configured.
  defp security_token(nil), do: []
  defp security_token(token), do: [security_token: token]

  # The origin only; addressing is `virtual_host` above and independent of it.
  # `ex_aws` wants the scheme with its `://` attached.
  defp endpoint(nil), do: []

  defp endpoint(%URI{scheme: scheme, host: host, port: port}) do
    [scheme: scheme <> "://", host: host, port: port]
  end
end
