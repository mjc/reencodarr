defmodule Reencodarr.TempCleaner do
  @moduledoc """
  Periodic cleanup of orphaned temp files from failed/crashed encodes.

  Scans the temp directory for files older than the max age and removes them.
  Runs on startup and periodically thereafter.
  """

  use GenServer
  import Ecto.Query
  require Logger

  alias Reencodarr.AbAv1.{Encode, Helper}
  alias Reencodarr.Media.Video
  alias Reencodarr.Repo

  # Clean every hour
  @cleanup_interval_ms :timer.hours(1)
  # Outputs are orphaned 12 hours after their final write.
  @max_age_seconds 43_200

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

    with {:ok, protected_paths} <- protected_paths(),
         {:ok, files} <- File.ls(temp_dir) do
      files
      |> Enum.map(&{&1, Path.join(temp_dir, &1)})
      |> Enum.reduce(0, fn {file, path}, count ->
        maybe_remove_orphan(file, path, now, protected_paths, count)
      end)
    else
      {:error, :enoent} ->
        0

      {:error, reason} ->
        Logger.warning("TempCleaner: failed to prepare cleanup: #{inspect(reason)}")
        0
    end
  end

  defp protected_paths do
    query =
      from v in Video,
        where: v.state in [:crf_searching, :encoding],
        select: %{id: v.id, path: v.path}

    {:ok,
     Repo.all(query)
     |> Enum.map(&Encode.output_file/1)
     |> MapSet.new()}
  rescue
    error -> {:error, {:ownership_lookup_failed, Exception.message(error)}}
  end

  defp maybe_remove_orphan(file, path, now, protected_paths, count) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        age = now - mtime

        cond do
          age <= @max_age_seconds ->
            count

          protected_path?(path, protected_paths) ->
            Logger.debug("TempCleaner: preserving owned artifact #{file}")
            count

          true ->
            remove_file(file, path, age, count)
        end

      _ ->
        count
    end
  end

  defp protected_path?(path, protected_paths) do
    Enum.any?(protected_paths, fn output_path ->
      path == output_path or String.starts_with?(path, output_path <> ".")
    end)
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
