defmodule Reencodarr.ManualScanner do
  use GenServer
  require Logger

  alias Reencodarr.Analyzer

  @file_extensions ["mp4", "mkv", "avi"]

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec init(any()) :: {:ok, nil}
  def init(_) do
    {:ok, nil}
  end

  @spec scan(String.t()) :: :ok
  def scan(path) do
    GenServer.cast(__MODULE__, {:scan, path})
  end

  @spec handle_cast({:scan, String.t()}, any()) :: {:noreply, any()}
  def handle_cast({:scan, path}, state) do
    find_video_files(path)
    {:noreply, state}
  end

  @spec handle_info({port(), {:data, String.t()}}, any()) :: {:noreply, any()}
  def handle_info({_port, {:data, data}}, state) do
    files = String.split(data, "\n", trim: true)

    Logger.debug("Found #{Enum.count(files)} video files")

    Enum.each(files, fn file ->
      Analyzer.process_path(%{path: file, service_id: nil, service_type: nil})
    end)

    {:noreply, state}
  end

  @spec handle_info({port(), {:exit_status, integer()}}, any()) :: {:noreply, any()}
  def handle_info({_port, {:exit_status, _status}}, state) do
    {:noreply, state}
  end

  @spec find_video_files(String.t()) :: port()
  defp find_video_files(path) do
    fd_path = find_fd_path()
    args = Enum.flat_map(@file_extensions, &["-e", &1]) ++ [".", path]
    Port.open({:spawn_executable, fd_path}, [:binary, :exit_status, args: args])
  end

  @spec find_fd_path() :: String.t()
  defp find_fd_path() do
    System.find_executable("fd") || System.find_executable("fd-find") ||
      raise "fd or fd-find executable not found"
  end
end