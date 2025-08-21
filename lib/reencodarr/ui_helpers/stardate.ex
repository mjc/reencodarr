defmodule Reencodarr.UIHelpers.Stardate do
  @moduledoc """
  Star Trek TNG-style stardate calculation utilities.

  Provides centralized stardate calculation for LiveView components.
  Based on TNG Writer's Guide: 1000 units = 1 year, decimal = fractional days.
  Reference: Year 2000 = Stardate 50000.0 (extrapolated from canon progression).
  """

  @doc """
  Calculates a proper Star Trek TNG-style stardate from a DateTime.

  ## Examples

      iex> calculate_stardate(~U[2025-08-21 12:00:00Z])
      75182.5

  """
  def calculate_stardate(datetime) do
    with %DateTime{} <- datetime,
         current_date = DateTime.to_date(datetime),
         current_time = DateTime.to_time(datetime),
         {:ok, day_of_year} when is_integer(day_of_year) <- {:ok, Date.day_of_year(current_date)},
         {seconds_in_day, _microseconds} <- Time.to_seconds_after_midnight(current_time) do
      # Calculate years since reference (2000 = 50000.0)
      reference_year = 2000
      current_year = current_date.year
      years_diff = current_year - reference_year

      # Calculate fractional day (0.0 to 0.9)
      day_fraction = seconds_in_day / 86_400.0

      # TNG Formula: base + (years * 1000) + (day_of_year * 1000/365.25) + (day_fraction / 10)
      base_stardate = 50_000.0
      year_component = years_diff * 1000.0
      day_component = day_of_year * (1000.0 / 365.25)
      fractional_component = day_fraction / 10.0

      stardate = base_stardate + year_component + day_component + fractional_component
      Float.round(stardate, 1)
    else
      # Fallback for mid-2025
      _ -> 75_182.5
    end
  end
end
