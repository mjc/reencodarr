defmodule Reencodarr.Core.Progress do
  @moduledoc """
  Progress tracking utilities for Reencodarr.

  Consolidates progress management functions from ProgressHelpers
  into the Core namespace with better organization.
  """

  @doc """
  Updates progress tracking with new measurements.

  ## Examples

      iex> Progress.update_progress(%{active_jobs: []}, %{job_id: 1, percent: 50})
      %{active_jobs: [%{job_id: 1, percent: 50}]}
  """
  @spec update_progress(map(), map()) :: map()
  def update_progress(current_progress, measurements) do
    # Extract job identifier (could be filename, job_id, etc.)
    job_key = get_job_key(measurements)

    # Update or add the progress entry
    updated_jobs =
      current_progress
      |> Map.get(:active_jobs, [])
      |> update_or_add_job(job_key, measurements)

    Map.put(current_progress, :active_jobs, updated_jobs)
  end

  @doc """
  Calculates percentage completion for a given progress state.

  ## Examples

      iex> Progress.calculate_percentage(completed: 50, total: 100)
      50.0
  """
  @spec calculate_percentage(keyword()) :: float()
  def calculate_percentage(opts) do
    completed = Keyword.get(opts, :completed, 0)
    total = Keyword.get(opts, :total, 1)

    if total > 0 do
      (completed / total * 100) |> Float.round(1)
    else
      0.0
    end
  end

  @doc """
  Formats progress information for display.

  ## Examples

      iex> Progress.format_progress(%{percent: 75.5, eta: "5 minutes"})
      "75.5% complete (ETA: 5 minutes)"
  """
  @spec format_progress(map()) :: String.t()
  def format_progress(progress) do
    percent = Map.get(progress, :percent, 0)
    eta = Map.get(progress, :eta, "unknown")

    "#{percent}% complete (ETA: #{eta})"
  end

  # Private helper to extract job key from measurements
  defp get_job_key(measurements) do
    Map.get(measurements, :filename) ||
      Map.get(measurements, :job_id) ||
      Map.get(measurements, :id) ||
      "default"
  end

  # Private helper to update or add job progress
  defp update_or_add_job(jobs, job_key, measurements) do
    case Enum.find_index(jobs, &(get_job_key(&1) == job_key)) do
      nil ->
        # Add new job
        [measurements | jobs]

      index ->
        # Update existing job
        List.replace_at(jobs, index, measurements)
    end
  end
end
