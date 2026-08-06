defmodule Reencodarr.AbAv1.WorkerAdmission do
  @moduledoc false

  @default_safety_bytes 5 * 1024 * 1024 * 1024

  @spec required_encode_bytes(map(), map(), keyword()) :: non_neg_integer()
  def required_encode_bytes(video, vmaf, opts \\ []) do
    source_bytes = video.size || 0
    safety_bytes = Keyword.get(opts, :safety_bytes, @default_safety_bytes)
    output_bytes = predicted_output_bytes(source_bytes, vmaf.percent)
    input_bytes = if Keyword.get(opts, :local?, false), do: 0, else: source_bytes

    safety_bytes + input_bytes + output_bytes
  end

  @spec encode_allowed?(non_neg_integer(), map(), map(), keyword()) :: boolean()
  def encode_allowed?(available_bytes, video, vmaf, opts \\ []) do
    available_bytes >= required_encode_bytes(video, vmaf, opts)
  end

  defp predicted_output_bytes(source_bytes, percent) when is_number(percent) and percent >= 0 do
    ceil(source_bytes * percent / 100)
  end

  defp predicted_output_bytes(source_bytes, _percent), do: source_bytes
end
