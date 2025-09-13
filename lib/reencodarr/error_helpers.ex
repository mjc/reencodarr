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
  Handles result tuples with automatic logging on errors.

  ## Examples

      iex> handle_result_with_logging({:ok, data}, &process_data/1, "Data processing")
      processed_data

      iex> handle_result_with_logging({:error, :timeout}, &process_data/1, "Data processing")
      {:error, :timeout}

  """
  def handle_result_with_logging(result, success_fn, context \\ "") do
    case result do
      {:ok, value} ->
        success_fn.(value)

      {:error, reason} ->
        log_and_return_error(reason, context)

      other ->
        log_and_return_error({:unexpected_result, other}, context)
    end
  end

  @doc """
  Handles results with custom error processing.

  ## Examples

      iex> handle_result({:ok, data}, &process_data/1, &handle_error/1)
      processed_data

  """
  def handle_result(result, success_fn, error_fn) do
    case result do
      {:ok, value} -> success_fn.(value)
      {:error, reason} -> error_fn.(reason)
      other -> error_fn.({:unexpected_result, other})
    end
  end

  @doc """
  Wraps a function call with error logging.

  ## Examples

      iex> with_error_logging(fn -> risky_operation() end, "Risky operation")
      result_or_logged_error

  """
  def with_error_logging(func, context \\ "") do
    func.()
  rescue
    e -> log_and_return_error({:exception, Exception.message(e)}, context)
  catch
    :exit, reason -> log_and_return_error({:exit, reason}, context)
    :throw, value -> log_and_return_error({:throw, value}, context)
  end

  @doc """
  Logs debug information for successful operations.

  ## Examples

      iex> log_success("User created", %{id: 1})
      :ok

  """
  def log_success(message, data \\ nil) do
    log_message = if data, do: "#{message}: #{inspect(data)}", else: message
    Logger.debug(log_message)
    :ok
  end

  @doc """
  Standard pattern for handling service API responses.

  ## Examples

      iex> handle_api_response({:ok, %{status: 200, body: data}}, "User fetch")
      {:ok, data}

      iex> handle_api_response({:error, reason}, "User fetch")
      {:error, reason}

  """
  def handle_api_response(response, context \\ "API call") do
    case response do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        log_success("#{context} succeeded")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        log_and_return_error({:http_error, status, body}, context)

      {:error, reason} ->
        log_and_return_error(reason, context)

      other ->
        log_and_return_error({:unexpected_response, other}, context)
    end
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
