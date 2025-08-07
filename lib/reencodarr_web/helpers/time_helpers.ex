defmodule ReencodarrWeb.TimeHelpers do
  @moduledoc """
  Unified time and duration utilities for the entire application.

  Consolidates time-related functionality from DashboardLiveHelpers, TimeUtils,
  TimeHelpers, ProgressHelpers, and AbAv1.Helper into a single comprehensive module.
  """

  # Time constants in seconds
  @seconds_per_minute 60
  @seconds_per_hour 3600
  @seconds_per_day 86_400
  # 30 days
  @seconds_per_month 2_592_000
  # 365 days
  @seconds_per_year 31_536_000

  # === RELATIVE TIME FORMATTING ===

  @doc """
  Formats a datetime as a relative time string (e.g., "2 hours ago", "3 days ago").

  Accepts DateTime, NaiveDateTime, or ISO8601 string formats.
  Returns "Never" for nil values and "Invalid date" for unparseable strings.

  ## Examples

      iex> TimeHelpers.relative_time(DateTime.utc_now())
      "0 seconds ago"

      iex> TimeHelpers.relative_time(nil)
      "Never"
  """
  def relative_time(nil), do: "Never"

  def relative_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed_datetime, _offset} -> relative_time(parsed_datetime)
      {:error, _} -> "Invalid date"
    end
  end

  def relative_time(%DateTime{} = datetime) do
    DateTime.utc_now()
    |> DateTime.diff(datetime, :second)
    |> format_relative_time()
  end

  def relative_time(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> relative_time()
  end

  def relative_time(datetime), do: inspect(datetime)

  # === STARDATE CALCULATION ===

  @doc """
  Calculates a proper Star Trek TNG-style stardate using the revised convention.

  Reference: Year 2000 = Stardate 50000.0 (extrapolated from canon progression).
  """
  def calculate_stardate(datetime) do
    case datetime do
      %DateTime{} = dt ->
        # Convert to local timezone for display if needed
        year = dt.year
        day_of_year = Date.day_of_year(dt)

        # Calculate stardate components
        # Each year adds 1000 to the stardate
        year_component = (year - 2000) * 1000

        # Each day adds ~2.7397 to the stardate (1000/365)
        day_component = (day_of_year - 1) * (1000 / 365)

        # Time of day component (fractional part)
        fractional_component =
          (dt.hour * 3600 + dt.minute * 60 + dt.second) / 86_400 * (1000 / 365)

        # Base stardate for year 2000
        base_stardate = 50_000.0

        # Calculate final stardate
        stardate = base_stardate + year_component + day_component + fractional_component

        # Round to 1 decimal place for display
        Float.round(stardate, 1)

      _ ->
        # Approximate stardate for August 2025
        75_625.5
    end
  end

  # === TIME CONVERSION UTILITIES ===

  @doc """
  Converts time values with units to seconds.

  ## Examples

      iex> TimeHelpers.to_seconds(5, "minutes")
      300

      iex> TimeHelpers.to_seconds(2, "hours")
      7200
  """
  @spec to_seconds(integer(), String.t()) :: integer()
  def to_seconds(time, unit) do
    unit
    |> String.trim_trailing("s")
    |> unit_to_multiplier()
    |> Kernel.*(time)
  end

  @doc """
  Converts time units to seconds for calculations.
  """
  def convert_to_seconds(time_value, unit) when is_number(time_value) do
    case String.downcase(unit) do
      "seconds" -> time_value
      "minutes" -> time_value * 60
      "hours" -> time_value * 3600
      "days" -> time_value * 86_400
      "weeks" -> time_value * 604_800
      # average month
      "months" -> time_value * 2_629_746
      # average year
      "years" -> time_value * 31_556_952
      _ -> time_value
    end
  end

  def convert_to_seconds(_, _), do: 0

  # === DURATION PARSING ===

  @doc """
  Parses duration strings in HH:MM:SS or MM:SS format to seconds.

  ## Examples

      iex> TimeHelpers.parse_duration("01:30:45")
      5445

      iex> TimeHelpers.parse_duration("30:45")
      1845
  """
  def parse_duration(duration) when is_binary(duration) do
    case String.split(duration, ":") do
      [hours, minutes, seconds] ->
        String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
          String.to_integer(seconds)

      [minutes, seconds] ->
        String.to_integer(minutes) * 60 + String.to_integer(seconds)

      [seconds] ->
        String.to_integer(seconds)

      _ ->
        0
    end
  end

  def parse_duration(duration) when is_number(duration), do: duration
  def parse_duration(_), do: 0

  # === DURATION FORMATTING ===

  @doc """
  Formats a duration value for display.

  ## Examples

      iex> TimeHelpers.format_duration(nil)
      "N/A"

      iex> TimeHelpers.format_duration(0)
      "N/A"

      iex> TimeHelpers.format_duration("5 minutes")
      "5 minutes"
  """
  def format_duration(nil), do: "N/A"
  def format_duration(0), do: "N/A"
  def format_duration(duration), do: to_string(duration)

  @doc """
  Formats ETA values as human-readable strings.
  """
  def format_eta(eta) when is_binary(eta), do: eta
  def format_eta(eta) when is_number(eta) and eta > 0, do: "#{eta}s"
  def format_eta(_), do: "N/A"

  # === UTILITY DATA ===

  @doc """
  Returns current stardate data for use in LiveViews.
  """
  def current_stardate_data do
    %{current_stardate: calculate_stardate(DateTime.utc_now())}
  end

  # === PRIVATE HELPERS ===

  # Private helper functions for formatting relative time differences
  defp format_relative_time(seconds) when seconds < @seconds_per_minute do
    pluralize(seconds, "second")
  end

  defp format_relative_time(seconds) when seconds < @seconds_per_hour do
    minutes = div(seconds, @seconds_per_minute)
    pluralize(minutes, "minute")
  end

  defp format_relative_time(seconds) when seconds < @seconds_per_day do
    hours = div(seconds, @seconds_per_hour)
    pluralize(hours, "hour")
  end

  defp format_relative_time(seconds) when seconds < @seconds_per_month do
    days = div(seconds, @seconds_per_day)
    pluralize(days, "day")
  end

  defp format_relative_time(seconds) when seconds < @seconds_per_year do
    months = div(seconds, @seconds_per_month)
    pluralize(months, "month")
  end

  defp format_relative_time(seconds) do
    years = div(seconds, @seconds_per_year)
    pluralize(years, "year")
  end

  defp pluralize(1, unit), do: "1 #{unit} ago"
  defp pluralize(n, unit), do: "#{n} #{unit}s ago"

  defp unit_to_multiplier(unit) do
    case String.downcase(unit) do
      "second" -> 1
      "minute" -> @seconds_per_minute
      "hour" -> @seconds_per_hour
      "day" -> @seconds_per_day
      "week" -> @seconds_per_day * 7
      "month" -> @seconds_per_month
      "year" -> @seconds_per_year
      _ -> 1
    end
  end
end
