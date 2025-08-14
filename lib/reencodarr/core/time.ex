defmodule Reencodarr.Core.Time do
  @moduledoc """
  Time and duration utilities for Reencodarr.

  Consolidates all time-related helper functions from TimeHelpers
  into the Core namespace with better organization.
  """

  @doc """
  Converts a time value to seconds based on the unit.

  ## Examples

      iex> Time.to_seconds(5, "minutes")
      300

      iex> Time.to_seconds(2, "hours")
      7200
  """
  @spec to_seconds(integer(), String.t()) :: integer()
  def to_seconds(time, unit) do
    case String.downcase(unit) do
      unit when unit in ["second", "seconds"] -> time
      unit when unit in ["minute", "minutes"] -> time * 60
      unit when unit in ["hour", "hours"] -> time * 3600
      unit when unit in ["day", "days"] -> time * 86400
      unit when unit in ["week", "weeks"] -> time * 604800
      unit when unit in ["month", "months"] -> time * 2_629_746
      unit when unit in ["year", "years"] -> time * 31_556_952
      _ -> time
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
  @spec relative_time(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def relative_time(nil), do: "never"

  def relative_time(datetime) do
    now = DateTime.utc_now()

    # Convert NaiveDateTime to DateTime if needed
    datetime =
      case datetime do
        %DateTime{} -> datetime
        %NaiveDateTime{} -> DateTime.from_naive!(datetime, "Etc/UTC")
      end

    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86400)} days ago"
      diff_seconds < 31_556_952 -> "#{div(diff_seconds, 2_629_746)} months ago"
      true -> "#{div(diff_seconds, 31_556_952)} years ago"
    end
  end

  # Private helper to parse time parts from captures
  defp parse_time_part(captures, key) do
    case Map.get(captures, key) do
      nil -> 0
      value when is_binary(value) -> String.to_integer(value)
      value when is_integer(value) -> value
      _ -> 0
    end
  end
end
