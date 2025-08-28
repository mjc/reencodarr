defmodule Reencodarr.Config do
  @moduledoc """
  Configuration helpers for the Reencodarr application.

  Provides centralized access to application configuration with sensible defaults.
  """

  @doc """
  Gets the list of file exclude patterns for video filtering.

  These patterns are used to filter out unwanted videos like samples, trailers, etc.
  Uses glob-style patterns that are matched against full file paths.

  ## Examples

      iex> Reencodarr.Config.exclude_patterns()
      []

      # With patterns configured:
      # ["**/sample/**", "**/trailer/**", "**/*sample*"]

  ## Configuration

  Configure in config.exs:

      config :reencodarr, :exclude_patterns, [
        "**/sample/**",
        "**/trailer/**",
        "**/*sample*",
        "**/*trailer*"
      ]
  """
  def exclude_patterns do
    Application.get_env(:reencodarr, :exclude_patterns, [])
  end

  @doc """
  Gets the temporary directory for video processing.

  ## Examples

      iex> Reencodarr.Config.temp_dir()
      "/tmp/ab-av1"
  """
  def temp_dir do
    Application.get_env(:reencodarr, :temp_dir, Path.join(System.tmp_dir!(), "ab-av1"))
  end
end
