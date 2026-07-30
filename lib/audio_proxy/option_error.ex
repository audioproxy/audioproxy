defmodule AudioProxy.OptionError do
  @moduledoc """
  A rejected options segment, as data (API doc §3, §5).

  Every parse or validation failure names the offending segment in its
  canonical `key:value` spelling plus a machine-readable reason. The HTTP
  slice renders these as the 422 JSON body; nothing here knows about HTTP.

  For cross-key conflicts (`br` with `q`) the segment is the one that could
  not be accepted given the rest, and `related` names its counterpart.
  """

  @typedoc """
  Why a segment was rejected.

  Grouped by origin: shape (`:empty_segment`..`:duplicate_key`), value domain
  (`:invalid_integer`..`:out_of_range`), and cross-key rules
  (`:mutually_exclusive`..`:fade_exceeds_duration`).
  """
  @type reason ::
          :empty_segment
          | :missing_value
          | :unknown_key
          | :duplicate_key
          | :invalid_integer
          | :invalid_number
          | :excessive_precision
          | :invalid_value
          | :out_of_range
          | :control_character
          | :mutually_exclusive
          | :requires_lossless_format
          | :requires_peaks_format
          | :sample_rate_above_lossy_cap
          | :fade_exceeds_duration

  @type t :: %__MODULE__{
          segment: String.t(),
          reason: reason(),
          related: String.t() | nil
        }

  @enforce_keys [:segment, :reason]
  defstruct [:segment, :reason, related: nil]

  @doc """
  Builds an error for `segment` with `reason`, optionally naming a `related`
  segment for cross-key conflicts.
  """
  @spec new(String.t(), reason(), String.t() | nil) :: t()
  def new(segment, reason, related \\ nil) when is_binary(segment) and is_atom(reason) do
    %__MODULE__{segment: segment, reason: reason, related: related}
  end

  @doc """
  A short human-readable sentence for `error`, for the 422 body's message.
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = error) do
    case error.reason do
      :empty_segment -> "empty options segment"
      :missing_value -> "segment #{inspect(error.segment)} has no value"
      :unknown_key -> "unknown option #{inspect(error.segment)}"
      :duplicate_key -> "option #{inspect(error.segment)} given more than once"
      :invalid_integer -> "#{inspect(error.segment)} expects an integer"
      :invalid_number -> "#{inspect(error.segment)} expects a number"
      :excessive_precision -> "#{inspect(error.segment)} exceeds millisecond precision"
      :invalid_value -> "#{inspect(error.segment)} is not a supported value"
      :out_of_range -> "#{inspect(error.segment)} is out of range"
      :control_character -> "#{inspect(error.segment)} contains a control character"
      :mutually_exclusive -> "#{inspect(error.segment)} conflicts with #{inspect(error.related)}"
      :requires_lossless_format -> "#{inspect(error.segment)} requires a lossless format"
      :requires_peaks_format -> "#{inspect(error.segment)} requires f:peaks"
      :sample_rate_above_lossy_cap -> "#{inspect(error.segment)} exceeds the 48 kHz lossy cap"
      :fade_exceeds_duration -> "#{inspect(error.segment)} is longer than the trimmed region"
    end
  end
end
