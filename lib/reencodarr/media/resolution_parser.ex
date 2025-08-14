defmodule Reencodarr.Media.ResolutionParser do
  @moduledoc """
  **DEPRECATED**: Use `Reencodarr.DataConverters` instead.

  This module has been consolidated into `Reencodarr.DataConverters`.

  ## Migration Guide
  - `ResolutionParser.parse/1` -> `DataConverters.parse_resolution/1`
  - `ResolutionParser.parse_with_fallback/2` -> `DataConverters.parse_resolution_with_fallback/2`
  - `ResolutionParser.format/1` -> `DataConverters.format_resolution/1`
  - `ResolutionParser.valid_resolution?/1` -> `DataConverters.valid_resolution?/1`
  """

  @deprecated "Use Reencodarr.DataConverters instead"

  @type resolution_tuple :: {width :: integer(), height :: integer()}
  @type resolution_input :: String.t() | resolution_tuple() | nil

  @doc """
  Parses resolution from various input formats into a standardized tuple.

  ## Examples

      iex> ResolutionParser.parse("1920x1080")
      {:ok, {1920, 1080}}

      iex> ResolutionParser.parse({1920, 1080})
      {:ok, {1920, 1080}}

      iex> ResolutionParser.parse("invalid")
      {:error, :invalid_format}
  """
  @spec parse(resolution_input()) :: {:ok, resolution_tuple()} | {:error, atom()}
  def parse(nil), do: {:error, :nil_input}

  def parse({width, height} = tuple) when is_integer(width) and is_integer(height) do
    {:ok, tuple}
  end

  def parse(resolution_string) when is_binary(resolution_string) do
    case String.split(resolution_string, "x") do
      [width_str, height_str] ->
        with {:ok, width} <- safe_parse_integer(width_str),
             {:ok, height} <- safe_parse_integer(height_str) do
          {:ok, {width, height}}
        else
          _ -> {:error, :invalid_format}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  def parse(_), do: {:error, :unsupported_type}

  @doc """
  Parses resolution with a fallback value.

  ## Examples

      iex> ResolutionParser.parse_with_fallback("1920x1080")
      {1920, 1080}

      iex> ResolutionParser.parse_with_fallback("invalid")
      {0, 0}
  """
  @spec parse_with_fallback(resolution_input(), resolution_tuple()) :: resolution_tuple()
  def parse_with_fallback(input, fallback \\ {0, 0}) do
    case parse(input) do
      {:ok, resolution} -> resolution
      {:error, _} -> fallback
    end
  end

  @doc """
  Formats a resolution tuple back to string format.

  ## Examples

      iex> ResolutionParser.format({1920, 1080})
      "1920x1080"
  """
  @spec format(resolution_tuple()) :: String.t()
  def format({width, height}), do: "#{width}x#{height}"

  @doc """
  Determines if a resolution represents a valid video size.
  """
  @spec valid_resolution?(resolution_tuple()) :: boolean()
  def valid_resolution?({width, height}) when is_integer(width) and is_integer(height) do
    width > 0 and height > 0 and width <= 7680 and height <= 4320
  end

  def valid_resolution?(_), do: false

  # Private helpers

  defp safe_parse_integer(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, :invalid_integer}
    end
  end
end
