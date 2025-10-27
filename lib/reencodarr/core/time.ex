defmodule Reencodarr.Core.Time do
  @moduledoc """
  Time and duration utilities for Reencodarr.

  Consolidates all time-related helper functions from TimeHelpers
  into the Core namespace with better organization.
  """

  @doc """
  Converts a time value to seconds based on the unit.

  ## Examples

      iex> Reencodarr.Core.Time.to_seconds(5, "minutes")
      300

      iex> Reencodarr.Core.Time.to_seconds(2, "hours")
      7200
  """
  @spec to_seconds(integer() | float(), String.t()) :: integer()
  def to_seconds(time, unit) do
    case String.downcase(unit) do
      unit when unit in ["second", "seconds"] -> trunc(time)
      unit when unit in ["minute", "minutes"] -> trunc(time * 60)
      unit when unit in ["hour", "hours"] -> trunc(time * 3600)
      unit when unit in ["day", "days"] -> trunc(time * 86_400)
      unit when unit in ["week", "weeks"] -> trunc(time * 604_800)
      unit when unit in ["month", "months"] -> trunc(time * 2_629_746)
      unit when unit in ["year", "years"] -> trunc(time * 31_556_952)
      _ -> trunc(time)
    end
  end

  @doc """
  Converts time captures from regex parsing to duration format.

  ## Examples

      iex> Time.convert_time_to_duration(%{"hours" => "1", "minutes" => "30"})
      %{hours: 1, minutes: 30, seconds: 0}
  """
  @spec convert_time_to_duration(map()) :: map()
  def convert_time_to_duration(captures) do
    %{
      hours: parse_time_part(captures, "hours"),
      minutes: parse_time_part(captures, "minutes"),
      seconds: parse_time_part(captures, "seconds")
    }
  end

  @doc """
  Formats a DateTime to relative time string.

  ## Examples

      iex> Time.relative_time(~U[2024-01-01 12:00:00Z])
      "about 1 year ago"
  """
  @spec relative_time(DateTime.t() | NaiveDateTime.t() | String.t() | nil) :: String.t()
  def relative_time(nil), do: "N/A"

  def relative_time(%DateTime{} = datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds} seconds ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86_400)} days ago"
      diff_seconds < 31_556_952 -> "#{div(diff_seconds, 2_629_746)} months ago"
      true -> "#{div(diff_seconds, 31_556_952)} years ago"
    end
  end

  def relative_time(%NaiveDateTime{} = datetime) do
    datetime |> DateTime.from_naive!("Etc/UTC") |> relative_time()
  end

  def relative_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> relative_time(dt)
      _ -> "N/A"
    end
  end

  def relative_time(_), do: "N/A"

  @doc """
  Formats duration from seconds to human-readable format.

  ## Examples

      iex> Time.format_duration(3661)
      "1h 1m 1s"

      iex> Time.format_duration(125)
      "2m 5s"

      iex> Time.format_duration(45)
      "45s"
  """
  @spec format_duration(number() | nil) :: String.t()
  def format_duration(nil), do: "N/A"
  def format_duration(0), do: "0s"

  def format_duration(seconds) when is_number(seconds) and seconds > 0 do
    hours = div(trunc(seconds), 3600)
    minutes = div(rem(trunc(seconds), 3600), 60)
    secs = rem(trunc(seconds), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  def format_duration(_), do: "N/A"

  @doc """
  Formats ETA with proper pluralization.

  ## Examples

      iex> Time.format_eta(1, "minute")
      "1 minute"

      iex> Time.format_eta(5, "minute")
      "5 minutes"
  """
  @spec format_eta(integer(), String.t()) :: String.t()
  def format_eta(eta, unit) when eta == 1, do: "#{eta} #{unit}"

  def format_eta(eta, unit) do
    # If unit already ends with 's', don't add another 's'
    if String.ends_with?(unit, "s") do
      "#{eta} #{unit}"
    else
      "#{eta} #{unit}s"
    end
  end

  @doc """
  Formats ETA from numeric seconds.

  ## Examples

      iex> Time.format_eta(3661)
      "1h 1m 1s"
  """
  @spec format_eta(number() | String.t() | nil) :: String.t()
  def format_eta(eta) when is_binary(eta), do: eta
  def format_eta(eta) when is_number(eta), do: format_duration(eta)
  def format_eta(_), do: "N/A"

  @doc """
  Formats a datetime as relative time with timezone support.

  ## Examples

      iex> Time.relative_time_with_timezone(nil, "UTC")
      "N/A"

      iex> Time.relative_time_with_timezone(~N[2023-01-01 12:00:00], "UTC")
      "..." # relative time string
  """
  @spec relative_time_with_timezone(NaiveDateTime.t() | nil, String.t()) :: String.t()
  def relative_time_with_timezone(nil, _timezone), do: "N/A"

  def relative_time_with_timezone(datetime, timezone)
      when is_binary(timezone) and timezone != "" do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.shift_zone!(timezone)
    |> relative_time()
  end

  def relative_time_with_timezone(datetime, _timezone) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.shift_zone!("UTC")
    |> relative_time()
  end

  # Private helper to parse time parts from captures
  defp parse_time_part(captures, key) do
    case Map.get(captures, key) do
      nil -> 0
      value when is_binary(value) -> parse_int(value, 0)
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  @spec parse_int(String.t() | integer() | nil, integer()) :: integer()
  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end
end
