defmodule AudioProxy.VariantStore.ParityLocalTest do
  @moduledoc """
  The shared seam assertions against the `file://` backend.

  The assertions themselves are in `AudioProxy.VariantStoreParity` and are run
  identically against `s3://` by `AudioProxy.VariantStore.ParityS3Test`. What
  is local-specific — the `tmp/` staging, the `.meta` sidecar, the fan-out —
  stays in `AudioProxy.VariantStore.LocalTest`.

  `async: false`, because the store root lives in the global config.
  """

  use ExUnit.Case, async: false
  use AudioProxy.VariantStoreParity

  import AudioProxy.ConfigHelper

  @moduletag tmp_dir: "variant_store_parity_local"

  setup %{tmp_dir: tmp_dir} do
    put_config(%{variant_store: {:file, tmp_dir}})
    :ok
  end
end
