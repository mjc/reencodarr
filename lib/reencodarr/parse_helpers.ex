defmodule Reencodarr.ParseHelpers do
  @moduledoc """
  Generic regex pattern matching and parsing utilities.

  This module provides a unified approach to parsing text using regex patterns,
  eliminating duplication across ab-av1 output parsing, MediaInfo parsing, and
  other text parsing throughout the application.
  """

  alias Reencodarr.Core.Parsers

  @doc """
  Parse a line using a regex pattern and field mapping configuration.

  Returns nil if no match, or a map with transformed fields if matched.

  ## Examples

      iex> pattern = ~r/crf\s(?<crf>\d+)\sVMAF\s(?<score>\d+\.\d+)/
      iex> field_mapping = %{
      ...>   crf: {"crf", &Parsers.parse_float/1},
      ...>   vmaf_score: {"score", &Parsers.parse_float/1}
      ...> }
      iex> ParseHelpers.parse_with_regex("crf 28 VMAF 95.5", pattern, field_mapping)
      %{crf: 28.0, vmaf_score: 95.5}

      iex> ParseHelpers.parse_with_regex("no match", pattern, field_mapping)
      nil
  """
  @spec parse_with_regex(String.t(), Regex.t(), map()) :: map() | nil
  def parse_with_regex(line, pattern, field_mapping) do
    case Regex.named_captures(pattern, line) do
      nil -> nil
      captures -> extract_fields(captures, field_mapping)
    end
  end

  @doc """
  Extract and transform fields from regex captures using field mapping.

  Field mapping format: %{output_key => {capture_key, transformer_function}}

  ## Examples

      iex> captures = %{"crf" => "28", "score" => "95.5"}
      iex> field_mapping = %{
      ...>   crf: {"crf", &Parsers.parse_float/1},
      ...>   vmaf_score: {"score", &Parsers.parse_float/1}
      ...> }
      iex> ParseHelpers.extract_fields(captures, field_mapping)
      %{crf: 28.0, vmaf_score: 95.5}
  """
  @spec extract_fields(map(), map()) :: map()
  def extract_fields(captures, field_mapping) do
    Enum.reduce(field_mapping, %{}, fn {output_key, {capture_key, transformer}}, acc ->
      case Map.get(captures, capture_key) do
        nil -> acc
        value -> Map.put(acc, output_key, transformer.(value))
      end
    end)
  end

  @doc """
  Try multiple patterns against a line until one matches.

  Returns the first successful match result, or nil if no patterns match.

  ## Examples

      iex> patterns = [
      ...>   {~r/simple (?<value>\d+)/, %{value: {"value", &Parsers.parse_int/1}}},
      ...>   {~r/complex (?<value>\d+\.\d+)/, %{value: {"value", &Parsers.parse_float/1}}}
      ...> ]
      iex> ParseHelpers.try_patterns("simple 42", patterns)
      %{value: 42}

      iex> ParseHelpers.try_patterns("complex 42.5", patterns)
      %{value: 42.5}

      iex> ParseHelpers.try_patterns("no match", patterns)
      nil
  """
  @spec try_patterns(String.t(), [{Regex.t(), map()}]) :: map() | nil
  def try_patterns(line, patterns) do
    Enum.find_value(patterns, fn {pattern, field_mapping} ->
      parse_with_regex(line, pattern, field_mapping)
    end)
  end

  @doc """
  Parse a line using a named pattern from a patterns map.

  This is useful when you have a centralized patterns map and want to parse
  using a specific pattern by key.

  ## Examples

      iex> patterns = %{
      ...>   simple: ~r/value (?<val>\d+)/,
      ...>   complex: ~r/data (?<val>\d+\.\d+)/
      ...> }
      iex> field_mapping = %{value: {"val", &Parsers.parse_float/1}}
      iex> ParseHelpers.parse_with_pattern("value 42", :simple, patterns, field_mapping)
      %{value: 42.0}
  """
  @spec parse_with_pattern(String.t(), atom(), map(), map()) :: map() | nil
  def parse_with_pattern(line, pattern_key, patterns, field_mapping) do
    case Map.get(patterns, pattern_key) do
      nil -> nil
      pattern -> parse_with_regex(line, pattern, field_mapping)
    end
  end

  @doc """
  Build a regex pattern from components with common pattern fragments.

  Useful for building complex patterns from reusable components.

  ## Examples

      iex> components = %{
      ...>   crf: "(?<crf>\\\\d+(?:\\\\.\\\\d+)?)",
      ...>   vmaf: "(?<score>\\\\d+\\\\.\\\\d+)"
      ...> }
      iex> pattern_template = "crf\\\\s\#{crf}\\\\sVMAF\\\\s\#{vmaf}"
      iex> ParseHelpers.build_pattern(pattern_template, components)
      "crf\\\\s(?<crf>\\\\d+(?:\\\\.\\\\d+)?)\\\\sVMAF\\\\s(?<score>\\\\d+\\\\.\\\\d+)"
  """
  @spec build_pattern(String.t(), map()) :: String.t()
  def build_pattern(template, components) do
    Enum.reduce(components, template, fn {key, pattern}, acc ->
      String.replace(acc, "\#{#{key}}", pattern)
    end)
  end

  @doc """
  Create a field mapping for common transformations.

  Provides shortcuts for common field transformations.

  ## Examples

      iex> ParseHelpers.field_mapping([
      ...>   {:crf, :float},
      ...>   {:score, :float},
      ...>   {:percent, :int},
      ...>   {:message, :string}
      ...> ])
      %{
        crf: {"crf", &Parsers.parse_float/1},
        score: {"score", &Parsers.parse_float/1},
        percent: {"percent", &Parsers.parse_int/1},
        message: {"message", &Function.identity/1}
      }
  """
  @spec field_mapping([{atom(), atom()} | {atom(), atom(), String.t()}]) :: map()
  def field_mapping(field_specs) do
    Enum.into(field_specs, %{}, fn
      {field, type} ->
        transformer = get_transformer(type)
        capture_key = Atom.to_string(field)
        {field, {capture_key, transformer}}

      {field, type, capture_key} ->
        transformer = get_transformer(type)
        {field, {capture_key, transformer}}
    end)
  end

  defp get_transformer(type) do
    case type do
      :int -> &Parsers.parse_int/1
      :float -> &Parsers.parse_float/1
      :string -> &Function.identity/1
      :duration -> &Parsers.parse_duration/1
      func when is_function(func) -> func
    end
  end

  @doc """
  Parse with multiple fallback patterns.

  Tries patterns in order until one matches. Useful for handling variations
  in output format.

  ## Examples

      iex> primary = {~r/format1 (?<val>\d+)/, %{value: {"val", &Parsers.parse_int/1}}}
      iex> fallback = {~r/format2 (?<val>\d+)/, %{value: {"val", &Parsers.parse_int/1}}}
      iex> ParseHelpers.parse_with_fallback("format2 42", primary, [fallback])
      %{value: 42}
  """
  @spec parse_with_fallback(String.t(), {Regex.t(), map()}, [{Regex.t(), map()}]) :: map() | nil
  def parse_with_fallback(line, {primary_pattern, primary_mapping}, fallback_patterns) do
    case parse_with_regex(line, primary_pattern, primary_mapping) do
      nil -> try_patterns(line, fallback_patterns)
      result -> result
    end
  end
end
