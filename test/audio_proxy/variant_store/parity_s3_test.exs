defmodule AudioProxy.VariantStore.ParityS3Test do
  @moduledoc """
  The shared seam assertions against the `s3://` backend, on a real store.

  The assertions are in `AudioProxy.VariantStoreParity` and are the same ones
  `AudioProxy.VariantStore.ParityLocalTest` runs against `file://`. That is
  the whole point: a difference between the two backends is a failure here
  rather than a surprise in a deployment.

  There is no fake store, for the reason `AudioProxy.S3Test` gives at length —
  a stub cannot verify a signature, so it agrees with whatever we send it.
  Tagged `:minio`, excluded by default, and it fails rather than skips when the
  store is missing. See `docs/development.md`.
  """

  use ExUnit.Case, async: false

  alias AudioProxy.MinioHelper

  # Before `use AudioProxy.VariantStoreParity`, and it has to be: a moduletag
  # is read when each test *registers*, so one written below the macro that
  # defines the tests tags nothing, and the whole parity run would try to reach
  # a store on every default `mix test`.
  @moduletag :minio
  @moduletag timeout: 120_000

  use AudioProxy.VariantStoreParity

  @bucket "audio-proxy-variants"

  setup do
    MinioHelper.configure!(%{variant_store: {:s3, @bucket}, serve_mode: :proxy})
    MinioHelper.ensure_bucket!(@bucket)
    :ok
  end
end
