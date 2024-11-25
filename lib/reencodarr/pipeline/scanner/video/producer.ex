defmodule Reencodarr.Pipeline.Scanner.Video.Producer do
  use GenStage
  alias Broadway.Message

  require Logger

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    file_stream = get_file_stream(path)
    library_id = get_library_id(path)
    {:producer, {file_stream, library_id}}
  end

  def handle_demand(demand, {file_stream, library_id}) when demand > 0 do
    events = Enum.take(file_stream, demand)
    messages = Enum.map(events, fn file_path ->
      case get_size(file_path) do
        {:ok, size} ->
          %Message{data: %{path: file_path, size: size, library_id: library_id}, acknowledger: {__MODULE__, :ack_id, nil}}
        {:error, reason} ->
          %Message{data: %{error: reason}, acknowledger: {__MODULE__, :ack_id, nil}}
      end
    end)
    {:noreply, messages, {file_stream, library_id}}
  end

  def ack(:ack_id, _successful, _failed) do
    # Logger.debug("Acknowledged successful messages: #{length(successful)}")
    # Logger.debug("Acknowledged failed messages: #{length(failed)}")
    :ok
  end

  defp get_file_stream(base_path) do
    Stream.resource(
      fn -> [base_path] end,
      fn
        [] -> {:halt, []}
        [path | rest] ->
          case File.ls(path) do
            {:ok, files} ->
              files = Enum.map(files, &Path.join(path, &1))
              video_files = Enum.filter(files, &video_file?/1)
              {video_files, rest ++ files}
            {:error, _} -> {[], rest}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp get_size(file_path) do
    case File.stat(file_path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_library_id(file_path) do
    libraries = Reencodarr.Media.list_libraries()
    case Enum.find(libraries, fn library -> String.starts_with?(file_path, library.path) end) do
      nil -> {:error, :library_not_found}
      library -> library.id
    end
  end

  defp video_file?(file_path) do
    ext = Path.extname(file_path) |> String.downcase()
    Enum.member?([".mp4", ".mkv", ".avi", ".mov"], ext)
  end
end
