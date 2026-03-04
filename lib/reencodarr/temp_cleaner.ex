defmodule Reencodarr.TempCleaner do
  @moduledoc """
  Periodic cleanup of orphaned temp files from failed/crashed encodes.

  Scans the temp directory for files older than the max age and removes them.
  Runs on startup and periodically thereafter.
  """

  use GenServer
  require Logger

  alias Reencodarr.AbAv1.Helper

  # Clean every hour
  @cleanup_interval_ms :timer.hours(1)
  # Files older than 24 hours are considered orphaned
  @max_age_seconds 86_400

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Clean up on startup
    send(self(), :cleanup)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_orphaned_files()
    schedule_cleanup()
    {:noreply, state}
  end

  @doc """
  Remove orphaned temp files older than the max age.
  Returns the number of files removed.
  """
  @spec cleanup_orphaned_files() :: non_neg_integer()
  def cleanup_orphaned_files do
    temp_dir = Helper.temp_dir()
    now = System.os_time(:second)

    case File.ls(temp_dir) do
      {:ok, files} ->
        files
        |> Enum.map(&{&1, Path.join(temp_dir, &1)})
        |> Enum.reduce(0, fn {file, path}, count ->
          maybe_remove_orphan(file, path, now, count)
        end)

      {:error, :enoent} ->
        0

      {:error, reason} ->
        Logger.warning("TempCleaner: failed to list temp dir: #{inspect(reason)}")
        0
    end
  end

  defp maybe_remove_orphan(file, path, now, count) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        age = now - mtime
        if age > @max_age_seconds, do: remove_file(file, path, age, count), else: count

      _ ->
        count
    end
  end

  defp remove_file(file, path, age, count) do
    case File.rm(path) do
      :ok ->
        Logger.info("TempCleaner: removed orphaned file #{file} (age: #{div(age, 3600)}h)")
        count + 1

      {:error, reason} ->
        Logger.warning("TempCleaner: failed to remove #{file}: #{inspect(reason)}")
        count
    end
  end

  @doc """
  Check available disk space on the temp directory's filesystem.
  Returns `{:ok, bytes_available}` or `{:error, reason}`.
  """
  @spec check_disk_space() :: {:ok, non_neg_integer()} | {:error, term()}
  def check_disk_space do
    temp_dir = Helper.temp_dir()
    check_disk_space(temp_dir)
  end

  @spec check_disk_space(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def check_disk_space(path) do
    case System.cmd("df", ["--output=avail", "-B1", path], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.trim()
        |> Integer.parse()
        |> case do
          {bytes, _} -> {:ok, bytes}
          :error -> {:error, "failed to parse df output: #{output}"}
        end

      {output, code} ->
        {:error, "df failed with exit code #{code}: #{output}"}
    end
  rescue
    e -> {:error, "disk space check failed: #{Exception.message(e)}"}
  end

  @doc """
  Check if there's enough disk space for encoding.
  Requires at least `min_bytes` available (default 5 GiB).
  """
  @spec sufficient_disk_space?(non_neg_integer()) :: boolean()
  def sufficient_disk_space?(min_bytes \\ 5_368_709_120) do
    case check_disk_space() do
      {:ok, available} -> available >= min_bytes
      {:error, _} -> true
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
