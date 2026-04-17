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

    do_retry(fun, 1, max_attempts, base_backoff)
  end

  defp do_retry(fun, attempt, max_attempts, base_backoff) do
    fun.()
  rescue
    error in Exqlite.Error ->
      if retryable_sqlite_error?(error) and attempt < max_attempts do
        backoff_and_retry(fun, error.message, attempt, max_attempts, base_backoff)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp backoff_and_retry(fun, error_message, attempt, max_attempts, base_backoff) do
    base = (:math.pow(2, attempt) * base_backoff) |> round()
    jitter = :rand.uniform(base |> div(2))
    backoff = base + jitter

    Logger.warning(
      "SQLite transient error (#{error_message}), retrying in #{backoff}ms " <>
        "(attempt #{attempt}/#{max_attempts})"
    )

    Process.sleep(backoff)
    do_retry(fun, attempt + 1, max_attempts, base_backoff)
  end

  defp retryable_sqlite_error?(%Exqlite.Error{message: message}) do
    message
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["database busy", "interrupted"]))
  end
end
