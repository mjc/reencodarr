defmodule Reencodarr.Statistics.AnalyzerProgress do
  @moduledoc "Represents the progress of an analyzer operation."

  @type t :: %__MODULE__{
          filename: :none | String.t(),
          percent: non_neg_integer(),
          current_file: :none | String.t(),
          total_files: non_neg_integer(),
          throughput: float(),
          rate_limit: non_neg_integer(),
          batch_size: non_neg_integer()
        }

  defstruct filename: :none,
            percent: 0,
            current_file: :none,
            total_files: 0,
            throughput: 0.0,
            rate_limit: 0,
            batch_size: 0

  @doc """
  Returns true if the progress has meaningful data to display.
  """
  def has_data?(%__MODULE__{filename: :none}), do: false
  def has_data?(%__MODULE__{filename: filename}) when is_binary(filename), do: true
  def has_data?(_), do: false

  @doc """
  Returns true if we have file count information.
  """
  def has_file_count?(%__MODULE__{total_files: total}) when is_number(total) and total > 0,
    do: true

  def has_file_count?(_), do: false
end
