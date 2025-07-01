defmodule ReencodarrWeb.Utils.TimeUtils do
  @moduledoc """
  Utilities for time formatting and display
  """

  # Time constants in seconds
  @seconds_per_minute 60
  @seconds_per_hour 3600
  @seconds_per_day 86400
  # 30 days
  @seconds_per_month 2_592_000
  # 365 days
  @seconds_per_year 31_536_000

  @doc """
  Formats a datetime as a relative time string (e.g., "2 hours ago", "3 days ago").

  Accepts DateTime, NaiveDateTime, or ISO8601 string formats.
  Returns "Never" for nil values and "Invalid date" for unparseable strings.

  ## Examples

      iex> TimeUtils.relative_time(DateTime.utc_now())
      "0 seconds ago"

      iex> TimeUtils.relative_time(nil)
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
end
