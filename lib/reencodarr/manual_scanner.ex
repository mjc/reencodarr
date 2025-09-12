defmodule Reencodarr.ManualScanner do
  @moduledoc "Implements manual scanning functionality for media files."

  use GenServer
  require Logger

  alias Reencodarr.Analyzer

  @file_extensions ["mp4", "mkv", "avi"]

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec init(any()) :: {:ok, %{fd_path: String.t() | nil}}
  def init(_) do
    case find_fd_path() do
      {:ok, fd_path} ->
        Logger.info("ManualScanner initialized with fd executable at: #{fd_path}")
        {:ok, %{fd_path: fd_path}}

      {:error, reason} ->
        Logger.warning("ManualScanner initialized without fd executable: #{reason}")
        {:ok, %{fd_path: nil}}
    end
  end

  @spec scan(String.t()) :: :ok
  def scan(path) do
    Logger.info("Received scan request for path: #{path}")
    GenServer.cast(__MODULE__, {:scan, path})
  end

  @spec handle_cast({:scan, String.t()}, %{fd_path: String.t() | nil}) ::
          {:noreply, %{fd_path: String.t() | nil}}
  def handle_cast({:scan, path}, %{fd_path: nil} = state) do
    Logger.warning("Scan requested for path #{path} but fd executable not available")
    {:noreply, state}
  end

  def handle_cast({:scan, path}, %{fd_path: fd_path} = state) when is_binary(fd_path) do
    Logger.info("Starting scan for path: #{path}")
    find_video_files(path, fd_path)
    {:noreply, state}
  end

  @spec handle_info({port(), {:data, String.t()}}, any()) :: {:noreply, any()}
  def handle_info({_port, {:data, data}}, state) do
    files = String.split(data, "\n", trim: true)
    Logger.debug("Found #{Enum.count(files)} video files")

    Enum.each(files, fn file ->
      Logger.debug("Processing file: #{file}")
      # Files found by manual scan should trigger analysis dispatch
      # The file should already exist in database from sync process
    end)

    # Trigger Broadway dispatch to check for videos needing analysis
    Analyzer.Broadway.dispatch_available()

    {:noreply, state}
  end

  @spec handle_info({port(), {:exit_status, integer()}}, any()) :: {:noreply, any()}
  def handle_info({_port, {:exit_status, status}}, state) do
    Logger.info("Scan process exited with status: #{status}")
    {:noreply, state}
  end

  @spec find_video_files(String.t(), String.t()) :: port()
  defp find_video_files(path, fd_path) do
    Logger.debug("Using fd executable at: #{fd_path}")
    args = Enum.flat_map(@file_extensions, &["-e", &1]) ++ [".", path]
    Logger.debug("Running fd with arguments: #{inspect(args)}")
    Port.open({:spawn_executable, fd_path}, [:binary, :exit_status, args: args])
  end

  @spec find_fd_path :: {:ok, String.t()} | {:error, String.t()}
  defp find_fd_path do
    case System.find_executable("fd") || System.find_executable("fd-find") do
      nil -> {:error, "fd or fd-find executable not found"}
      path -> {:ok, path}
    end
  end
end
