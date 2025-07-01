defmodule Reencodarr.Statistics.CrfSearchProgress do
  @moduledoc "Holds progress data for CRF quality search operations."
  defstruct filename: :none, percent: 0, eta: 0, fps: 0, crf: nil, score: nil

  @doc """
  Returns true if the progress has meaningful data to display.
  """
  def has_data?(%__MODULE__{filename: :none}), do: false
  def has_data?(%__MODULE__{filename: filename}) when is_binary(filename), do: true
  def has_data?(_), do: false

  @doc """
  Returns true if CRF value is meaningful (not nil and > 0).
  """
  def has_crf?(%__MODULE__{crf: crf}) when is_number(crf) and crf > 0, do: true
  def has_crf?(_), do: false

  @doc """
  Returns true if VMAF score is meaningful (not nil and > 0).
  """
  def has_score?(%__MODULE__{score: score}) when is_number(score) and score > 0, do: true
  def has_score?(_), do: false

  @doc """
  Returns true if progress percentage is meaningful (> 0).
  """
  def has_percent?(%__MODULE__{percent: percent}) when is_number(percent) and percent > 0,
    do: true

  def has_percent?(_), do: false

  @doc """
  Returns true if FPS is meaningful (> 0).
  """
  def has_fps?(%__MODULE__{fps: fps}) when is_number(fps) and fps > 0, do: true
  def has_fps?(_), do: false

  @doc """
  Returns true if ETA is meaningful (not nil and not 0).
  """
  def has_eta?(%__MODULE__{eta: eta}) when eta != nil and eta != 0, do: true
  def has_eta?(_), do: false

  @doc """
  Formats the filename for display (removes path, shows just basename).
  """
  def display_filename(%__MODULE__{filename: :none}), do: "No file"

  def display_filename(%__MODULE__{filename: filename}) when is_binary(filename) do
    Path.basename(filename)
  end
end
