defmodule Reencodarr.Scanner do
  use GenServer
  require Logger

  @file_extensions ["mp4", "mkv", "avi"]

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    {:ok, nil}
  end

  def scan(path) do
    GenServer.cast(__MODULE__, {:scan, path})
  end

  def handle_cast({:scan, path}, state) do
    find_video_files(path)
    {:noreply, state}
  end

  def handle_info({_port, {:data, data}}, state) do
    data
    |> String.split("\n", trim: true)
    |> Enum.map(&publish_video_file/1)
    |> tap(&Logger.info("Found #{Enum.count(&1)} video files"))
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, _status}}, state) do
    {:noreply, state}
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
    message = %{path: file_path}
    :ok = Phoenix.PubSub.broadcast(Reencodarr.PubSub, "video:found", message)
  end
end
