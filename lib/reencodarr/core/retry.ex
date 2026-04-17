defmodule Reencodarr.Core.Retry do
  @moduledoc """
  Retry utilities for handling transient database errors.
  """

  require Logger

  @doc """
  Retries a function with exponential backoff when SQLite returns a transient
  concurrency error.

  ## Options
  Retryable SQLite errors currently include `Database busy` and `interrupted`.

  - `:max_attempts` - Maximum number of retry attempts (default: 5)
  - `:base_backoff_ms` - Base backoff time in milliseconds (default: 100)
  - `:label` - Short description of the operation being retried for logging

  ## Examples

      iex> retry_on_db_busy(fn -> Repo.update(changeset) end)
      {:ok, updated_record}

      iex> retry_on_db_busy(fn -> Repo.transaction(fn -> ... end) end, max_attempts: 3)
      {:ok, result}
  """
  @spec retry_on_db_busy((-> any()), keyword()) :: any()
  def retry_on_db_busy(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 5)
    base_backoff = Keyword.get(opts, :base_backoff_ms, 100)
    label = Keyword.get(opts, :label)
    caller = capture_caller()

    do_retry(fun, 1, max_attempts, base_backoff, label, caller)
  end

  defp do_retry(fun, attempt, max_attempts, base_backoff, label, caller) do
    fun.()
  rescue
    error in Exqlite.Error ->
      if retryable_sqlite_error?(error) and attempt < max_attempts do
        backoff_and_retry(fun, error.message, attempt, max_attempts, base_backoff, label, caller)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp backoff_and_retry(fun, error_message, attempt, max_attempts, base_backoff, label, caller) do
    base = (:math.pow(2, attempt) * base_backoff) |> round()
    jitter = :rand.uniform(base |> div(2))
    backoff = base + jitter

    operation =
      case label do
        nil -> ""
        "" -> ""
        value -> " during #{value}"
      end

    caller_context =
      case caller do
        nil -> ""
        value -> " (caller #{value})"
      end

    Logger.warning(
      "SQLite transient error#{operation}#{caller_context} (#{error_message}), retrying in #{backoff}ms " <>
        "(attempt #{attempt}/#{max_attempts})"
    )

    Process.sleep(backoff)
    do_retry(fun, attempt + 1, max_attempts, base_backoff, label, caller)
  end

  defp capture_caller do
    with {:current_stacktrace, stacktrace} <- Process.info(self(), :current_stacktrace) do
      stacktrace
      |> Enum.reject(fn
        {__MODULE__, _, _, _} ->
          true

        {Process, :info, 2, _} ->
          true

        {:erlang, :process_info, 2, _} ->
          true

        {module, _, _, _} when is_atom(module) ->
          module
          |> Atom.to_string()
          |> String.starts_with?("Elixir.ExUnit.")

        _ ->
          false
      end)
      |> Enum.find_value(&format_stacktrace_entry/1)
    end
  end

  defp format_stacktrace_entry({module, function, arity, _location})
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    function_name = Atom.to_string(function)

    if String.starts_with?(function_name, "-") do
      nil
    else
      "#{inspect(module)}.#{function}/#{arity}"
    end
  end

  defp format_stacktrace_entry(_entry), do: nil

  defp retryable_sqlite_error?(%Exqlite.Error{message: message}) do
    message
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["database busy", "interrupted"]))
  end
end
