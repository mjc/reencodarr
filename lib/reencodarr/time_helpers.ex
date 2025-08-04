defmodule Reencodarr.TimeHelpers do
  @moduledoc """
  Unified time and duration utilities for Reencodarr.

  Consolidates time-related functionality from ProgressHelpers, TimeUtils,
  and AbAv1.Helper into a single module.
  """

  # Time constants in seconds
  @seconds_per_minute 60
  @seconds_per_hour 3600
  @seconds_per_day 86_400
  # 30 days
  @seconds_per_month 2_592_000
  # 365 days
  @seconds_per_year 31_536_000

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
  Parses duration strings in HH:MM:SS or MM:SS format to seconds.

  ## Examples

      iex> TimeHelpers.parse_duration("01:30:45")
      5445

      iex> TimeHelpers.parse_duration("30:45")
      1845
  """
  @spec parse_duration(String.t() | number()) :: number()
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

  @doc """
  Converts time with unit to a duration map with time and unit fields.
  """
  @spec convert_time_to_duration(map()) :: map()
  def convert_time_to_duration(%{"time" => time, "unit" => unit} = captures) do
    case Integer.parse(time) do
      {time_value, _} ->
        Map.put(captures, "time", to_seconds(time_value, unit)) |> Map.delete("unit")

      :error ->
        captures
    end
  end

  def convert_time_to_duration(captures), do: captures

  # Private functions

  defp unit_to_multiplier("minute"), do: @seconds_per_minute
  defp unit_to_multiplier("hour"), do: @seconds_per_hour
  defp unit_to_multiplier("day"), do: @seconds_per_day
  defp unit_to_multiplier("week"), do: 604_800
  defp unit_to_multiplier("month"), do: @seconds_per_month
  defp unit_to_multiplier("year"), do: @seconds_per_year
  defp unit_to_multiplier(_), do: 1

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
end
