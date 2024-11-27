defmodule Reencodarr.Scanner do
  use GenServer
  require Logger

  @work_interval 100
  @file_extensions ["mp4", "mkv", "avi"]

  def start_link(path) do
    GenServer.start_link(__MODULE__, path, name: __MODULE__)
  end

  def init(path) do
    schedule_work()
    {:ok, path}
  end

  def handle_info(:work, path) do
    find_video_files(path)
    schedule_work()
    {:noreply, path}
  end

  def handle_info({_port, {:data, data}}, path) do
    data
    |> String.split("\n", trim: true)
    |> Enum.each(&publish_video_file/1)
    {:noreply, path}
  end

  def handle_info({_port, {:exit_status, _status}}, path) do
    {:stop, :normal, path}
  end

  defp schedule_work() do
    Process.send_after(self(), :work, @work_interval)
  end

  defp find_video_files(path) do
    fd_path = find_fd_path()
    args = Enum.flat_map(@file_extensions, &["-e", &1]) ++ [".", path]
    Port.open({:spawn_executable, fd_path}, [:binary, :exit_status, args: args])
  end

  defp find_fd_path() do
    System.find_executable("fd") || System.find_executable("fd-find") || raise "fd or fd-find executable not found"
  end

  defp publish_video_file(file_path) do
    case File.stat(file_path) do
      {:ok, file_info} ->
        message = %{path: file_path, size: file_info.size, modified_time: file_info.mtime}
        :ok = Phoenix.PubSub.broadcast(Reencodarr.PubSub, "video:found", message)
      {:error, _reason} ->
        Logger.error("Failed to stat file: #{file_path}")
    end
  end
end
