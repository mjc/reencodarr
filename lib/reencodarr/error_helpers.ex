defmodule Reencodarr.ErrorHelpers do
  @moduledoc """
  Consolidated error handling utilities to eliminate duplication.

  Provides reusable patterns for common error handling scenarios
  including logging, result processing, and error propagation.
  """

  require Logger

  @doc """
  Logs an error and returns a consistent error tuple.

  ## Examples

      iex> log_and_return_error(:connection_failed, "API request")
      {:error, :connection_failed}

  """
  def log_and_return_error(reason, context \\ "") do
    context_msg = if context != "", do: "#{context} failed: ", else: ""
    Logger.error("#{context_msg}#{inspect(reason)}")
    {:error, reason}
  end

  @doc """
  Creates a standardized error for missing configuration.
  """
  def config_not_found_error(service_name) do
    Logger.error("#{service_name} config not found")
    {:error, :config_not_found}
  end

  @doc """
  Handles common nil value scenarios with logging.
  """
  def handle_nil_value(value, field_name, context \\ "") do
    case value do
      nil ->
        message = "#{field_name} is null"
        full_message = if context != "", do: "#{context}: #{message}", else: message
        Logger.error(full_message)
        {:error, {:nil_value, field_name}}

      value ->
        {:ok, value}
    end
  end

  @doc """
  Handles error cases by logging and returning a default value.

  Common pattern: when operation fails but process should continue with fallback.

  ## Examples

      iex> handle_error_with_default({:ok, data}, "backup", "Operation")
      data

      iex> handle_error_with_default({:error, :timeout}, "backup", "Operation")
      "backup"

  """
  def handle_error_with_default(result, default_value, context \\ "") do
    case result do
      {:ok, value} ->
        value

      {:error, reason} ->
        log_error_with_context(reason, context)
        default_value

      other ->
        log_error_with_context({:unexpected_result, other}, context)
        default_value
    end
  end

  @doc """
  Handles error cases by logging with warning level and returning a default value.

  Used when failure is expected but not critical.
  """
  def handle_error_with_warning(result, default_value, context \\ "") do
    case result do
      {:ok, value} ->
        value

      {:error, reason} ->
        context_msg = if context != "", do: "#{context}: ", else: ""
        Logger.warning("#{context_msg}#{inspect(reason)} (continuing anyway)")
        default_value

      other ->
        context_msg = if context != "", do: "#{context}: ", else: ""
        Logger.warning("#{context_msg}#{inspect(other)} (continuing anyway)")
        default_value
    end
  end

  # Private helper for consistent error logging
  defp log_error_with_context(reason, context) do
    context_msg = if context != "", do: "#{context}: ", else: ""
    Logger.error("#{context_msg}#{inspect(reason)}")
  end
end
