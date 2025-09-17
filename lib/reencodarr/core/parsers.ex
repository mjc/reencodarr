defmodule Reencodarr.Core.Parsers do
  @moduledoc """
  Generic parsing utilities for various data types and formats.

  This module provides safe parsing functions with fallback defaults
  for common data transformations needed throughout the application.
  """

  require Logger

  @doc """
  Parses duration string in various formats to seconds.

  Supports formats like:
  - "1:23:45" (1 hour, 23 minutes, 45 seconds)
  - "23:45" (23 minutes, 45 seconds)
  - "45" (45 seconds)

  ## Examples

      iex> Parsers.parse_duration("1:23:45")
      5025

      iex> Parsers.parse_duration("23:45")
      1425

      iex> Parsers.parse_duration(3600.0)
      3600.0
  """
  @spec parse_duration(String.t() | number()) :: number()
  def parse_duration(duration) when is_binary(duration) do
    # Try parsing as float first (e.g., "123.45")
    case Float.parse(duration) do
      {parsed_duration, ""} ->
        parsed_duration

      _ ->
        # Fall back to time format parsing (e.g., "1:23:45")
        parse_time_format(duration)
    end
  end

  def parse_duration(duration) when is_number(duration), do: duration * 1.0
  def parse_duration(_), do: 0.0

  # Parse time format strings like "1:23:45", "23:45", or "45"
  defp parse_time_format(duration) do
    case String.split(duration, ":") do
      [hours, minutes, seconds] -> parse_hms(hours, minutes, seconds)
      [minutes, seconds] -> parse_ms(minutes, seconds)
      [seconds] -> parse_s(seconds)
      _ -> 0
    end
  end

  defp parse_hms(hours, minutes, seconds) do
    with {h, ""} <- Integer.parse(hours),
         {m, ""} <- Integer.parse(minutes),
         {s, ""} <- Integer.parse(seconds) do
      h * 3600 + m * 60 + s
    else
      _ -> 0
    end
  end

  defp parse_ms(minutes, seconds) do
    with {m, ""} <- Integer.parse(minutes),
         {s, ""} <- Integer.parse(seconds) do
      m * 60 + s
    else
      _ -> 0
    end
  end

  defp parse_s(seconds) do
    case Integer.parse(seconds) do
      {s, ""} -> s
      _ -> 0
    end
  end

  @doc """
  Safely parses an integer with fallback to default value.

  ## Examples

      iex> Parsers.parse_int("123", 0)
      123

      iex> Parsers.parse_int("invalid", 42)
      42

      iex> Parsers.parse_int(456, 0)
      456
  """
  @spec parse_int(any(), integer()) :: integer()
  def parse_int(val, default \\ 0)
  def parse_int(val, _default) when is_integer(val), do: val

  def parse_int(val, _default) when is_float(val) do
    # Handle float to integer conversion
    round(val)
  end

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} ->
        i

      :error ->
        # Try parsing as float first, then convert to integer
        case Float.parse(val) do
          {f, _} -> round(f)
          :error -> default
        end
    end
  end

  def parse_int(_, default), do: default

  @doc """
  Safely parses a float with fallback to default value.

  ## Examples

      iex> Parsers.parse_float("123.45", 0.0)
      123.45

      iex> Parsers.parse_float("invalid", 3.14)
      3.14

      iex> Parsers.parse_float(456.78, 0.0)
      456.78
  """
  @spec parse_float(any(), float()) :: float()
  def parse_float(val, default \\ 0.0)
  def parse_float(val, _default) when is_float(val), do: val

  def parse_float(val, _default) when is_integer(val) do
    # Handle integer to float conversion
    val * 1.0
  end

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} ->
        f

      :error ->
        # Try parsing as integer first, then convert to float
        case Integer.parse(val) do
          {i, _} -> i * 1.0
          :error -> default
        end
    end
  end

  def parse_float(_, default), do: default

  @doc """
  Safely parses a boolean value from various inputs.

  Handles strings, integers, and boolean values, converting common
  representations to true/false with fallback to default value.

  ## Examples

      iex> Parsers.parse_boolean("true", false)
      true

      iex> Parsers.parse_boolean(1, false)
      true

      iex> Parsers.parse_boolean("invalid", true)
      true
  """
  @spec parse_boolean(any(), boolean()) :: boolean()
  def parse_boolean(val, default \\ false)
  def parse_boolean(true, _default), do: true
  def parse_boolean(false, _default), do: false
  def parse_boolean("true", _default), do: true
  def parse_boolean("false", _default), do: false
  def parse_boolean("True", _default), do: true
  def parse_boolean("False", _default), do: false
  def parse_boolean("TRUE", _default), do: true
  def parse_boolean("FALSE", _default), do: false
  def parse_boolean("yes", _default), do: true
  def parse_boolean("no", _default), do: false
  def parse_boolean("Yes", _default), do: true
  def parse_boolean("No", _default), do: false
  def parse_boolean("YES", _default), do: true
  def parse_boolean("NO", _default), do: false
  def parse_boolean("1", _default), do: true
  def parse_boolean("0", _default), do: false
  def parse_boolean(1, _default), do: true
  def parse_boolean(0, _default), do: false
  def parse_boolean(_, default), do: default

  @doc """
  Gets the first non-nil value from a list.

  ## Examples

      iex> Parsers.get_first([nil, "", "hello", "world"])
      "hello"

      iex> Parsers.get_first([nil, nil], "default")
      "default"
  """
  @spec get_first(list(), any()) :: any()
  def get_first(list, default \\ nil) do
    Enum.find(list, & &1) || default
  end

  @doc """
  Creates a field mapping configuration for regex pattern parsing.

  ## Examples

      iex> field_mapping([{:crf, :float}, {:score, :float, "score"}])
      %{crf: {:float, "crf"}, score: {:float, "score"}}
  """
  @spec field_mapping(list()) :: map()
  def field_mapping(fields) do
    fields
    |> Enum.reduce(%{}, fn
      {key, type}, acc ->
        Map.put(acc, key, {type, to_string(key)})

      {key, type, capture_key}, acc ->
        Map.put(acc, key, {type, capture_key})
    end)
  end

  @doc """
  Parses a line with a regex pattern and field mapping.

  ## Examples

      iex> pattern = ~r/crf (?<crf>\d+)/
      iex> mapping = %{crf: {:float, "crf"}}
      iex> parse_with_pattern("crf 28", :test, %{test: pattern}, mapping)
      {:ok, %{crf: 28.0}}
  """
  @spec parse_with_pattern(String.t(), atom(), map(), map()) :: {:ok, map()} | {:error, :no_match}
  def parse_with_pattern(line, pattern_key, patterns, field_mapping) do
    pattern = Map.get(patterns, pattern_key)

    case Regex.named_captures(pattern, line) do
      nil -> {:error, :no_match}
      captures -> {:ok, extract_fields(captures, field_mapping)}
    end
  end

  # Extract and convert fields from regex captures
  defp extract_fields(captures, field_mapping) do
    field_mapping
    |> Enum.reduce(%{}, fn {key, {type, capture_key}}, acc ->
      case Map.get(captures, capture_key) do
        nil -> acc
        value -> Map.put(acc, key, convert_value(value, type))
      end
    end)
  end

  # Convert captured string values to appropriate types
  @spec convert_value(String.t(), :int) :: integer()
  defp convert_value(value, :int) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  @spec convert_value(String.t(), :float) :: float()
  defp convert_value(value, :float) do
    case String.contains?(value, ".") do
      true ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> 0.0
        end

      false ->
        case Integer.parse(value) do
          {int, ""} -> int * 1.0
          _ -> 0.0
        end
    end
  end

  @spec convert_value(String.t(), :string) :: String.t()
  defp convert_value(value, :string), do: value

  @doc """
  Parses an integer string with exact matching (no trailing characters allowed).

  Returns {:ok, integer} on success, {:error, reason} on failure.

  ## Examples

      iex> Parsers.parse_integer_exact("123")
      {:ok, 123}

      iex> Parsers.parse_integer_exact("123abc")
      {:error, :invalid_format}

      iex> Parsers.parse_integer_exact("")
      {:error, :invalid_format}
  """
  @spec parse_integer_exact(String.t()) :: {:ok, integer()} | {:error, atom()}
  def parse_integer_exact(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      {_int, _remainder} -> {:error, :invalid_format}
      :error -> {:error, :invalid_format}
    end
  end

  def parse_integer_exact(_), do: {:error, :invalid_input}

  @doc """
  Parses a float string with exact matching (no trailing characters allowed).

  Returns {:ok, float} on success, {:error, reason} on failure.

  ## Examples

      iex> Parsers.parse_float_exact("123.45")
      {:ok, 123.45}

      iex> Parsers.parse_float_exact("123.45abc")
      {:error, :invalid_format}
  """
  @spec parse_float_exact(String.t()) :: {:ok, float()} | {:error, atom()}
  def parse_float_exact(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      {_float, _remainder} -> {:error, :invalid_format}
      :error -> {:error, :invalid_format}
    end
  end

  def parse_float_exact(_), do: {:error, :invalid_input}

  @doc """
  Extracts the first valid year from text using simple string parsing.

  Looks for 4-digit years (1950-2030) in common video file patterns,
  prioritizing bracketed formats over standalone numbers.

  ## Examples

      iex> Parsers.extract_year_from_text("The Movie (2008) HD")
      2008

      iex> Parsers.extract_year_from_text("Show.S01E01.2008.mkv")
      2008

      iex> Parsers.extract_year_from_text("No year here")
      nil

  """
  @spec extract_year_from_text(String.t() | nil) :: integer() | nil
  def extract_year_from_text(nil), do: nil
  def extract_year_from_text(""), do: nil

  def extract_year_from_text(text) when is_binary(text) do
    # Check each pattern in priority order
    find_year_in_parentheses(text) ||
      find_year_in_brackets(text) ||
      find_year_with_dots(text) ||
      find_year_with_spaces(text) ||
      find_standalone_year(text)
  end

  # Find year like (2008)
  defp find_year_in_parentheses(text) do
    find_year_between_chars(text, "(", ")")
  end

  # Find year like [2008]
  defp find_year_in_brackets(text) do
    find_year_between_chars(text, "[", "]")
  end

  # Find year like .2008.
  defp find_year_with_dots(text) do
    find_year_between_chars(text, ".", ".")
  end

  # Find year like " 2008 " (with spaces)
  defp find_year_with_spaces(text) do
    find_year_between_chars(text, " ", " ")
  end

  # Find standalone 4-digit year anywhere in string
  defp find_standalone_year(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.find_value(&check_year_candidate/1)
  end

  # Check if 4 characters form a valid year
  defp check_year_candidate(four_chars) do
    year_str = Enum.join(four_chars)

    if all_digits?(year_str) do
      parse_and_validate_year(year_str)
    end
  end

  # Parse year string and validate range
  defp parse_and_validate_year(year_str) do
    case Integer.parse(year_str) do
      {year, ""} when year >= 1950 and year <= 2030 -> year
      _ -> nil
    end
  end

  # Helper to find year between two delimiter characters
  defp find_year_between_chars(text, open_char, close_char) do
    case String.split(text, open_char) do
      # No opening delimiter found
      [_] ->
        nil

      parts ->
        parts
        # Skip the part before first delimiter
        |> Enum.drop(1)
        |> Enum.find_value(&extract_year_from_part(&1, close_char))
    end
  end

  # Extract year from a text part after finding opening delimiter
  defp extract_year_from_part(part, close_char) do
    case String.split(part, close_char, parts: 2) do
      [potential_year | _] when byte_size(potential_year) == 4 ->
        if all_digits?(potential_year) do
          parse_and_validate_year(potential_year)
        end

      _ ->
        nil
    end
  end

  # Check if a string contains only digits
  defp all_digits?(str) do
    String.length(str) == 4 and
      String.to_charlist(str) |> Enum.all?(&(&1 >= ?0 and &1 <= ?9))
  end
end
