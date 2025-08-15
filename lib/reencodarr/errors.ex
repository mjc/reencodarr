defmodule Reencodarr.Errors do
  @moduledoc """
  Centralized error handling utilities.

  Provides consistent error handling patterns with logging
  across all services and modules.
  """

  require Logger

  @doc """
  Logs an error and returns a standardized error tuple.
  """
  def log_and_return_error(message, error_type \\ :error) do
    Logger.error(message)
    {error_type, message}
  end

  @doc """
  Handles a result tuple with logging for errors.
  """
  def handle_result_with_logging(result, success_message, error_context) do
    case result do
      {:ok, data} ->
        Logger.info(success_message)
        {:ok, data}

      {:error, reason} ->
        error_msg = "#{error_context}: #{inspect(reason)}"
        log_and_return_error(error_msg)
    end
  end

  @doc """
  Handles API response with standardized error logging.
  """
  def handle_api_response(response, service_name) do
    case response do
      {:ok, data} ->
        Logger.debug("#{service_name} API call successful")
        {:ok, data}

      {:error, reason} ->
        error_msg = "#{service_name} API call failed: #{inspect(reason)}"
        log_and_return_error(error_msg)
    end
  end

  @doc """
  Handles nil values with appropriate error response.
  """
  def handle_nil_value(value, field_name, _default \\ nil) do
    case value do
      nil ->
        error_msg = "#{field_name} not found or is nil"
        Logger.warning(error_msg)
        {:error, error_msg}

      val ->
        {:ok, val}
    end
  end

  @doc """
  Standard configuration not found error.
  """
  def config_not_found_error(service_type) do
    error_msg = "No valid #{service_type} configuration found"
    log_and_return_error(error_msg, :config_error)
  end

  @doc """
  Wraps a function call with error handling and logging.
  """
  def with_error_handling(fun, context) when is_function(fun, 0) do
    try do
      case fun.() do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          error_msg = "#{context}: #{inspect(reason)}"
          log_and_return_error(error_msg)

        result ->
          result
      end
    rescue
      exception ->
        error_msg = "#{context} failed with exception: #{inspect(exception)}"
        log_and_return_error(error_msg)
    end
  end
end
