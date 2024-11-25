defmodule Reencodarr.Pipeline.Scanner.Video.Producer do
  use GenStage
  alias Broadway.Message

  require Logger

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    file_list = get_file_list(path)
    library_id = get_library_id(path)
    {:producer, {file_list, library_id}}
  end

  def handle_demand(demand, {file_list, library_id}) when demand > 0 do
    {events, remaining_files} = Enum.split(file_list, demand)

    messages =
      Enum.map(events, fn file_path ->
        case get_size(file_path) do
          {:ok, size} ->
            %Message{
              data: %{path: file_path, size: size, library_id: library_id},
              acknowledger: {__MODULE__, :ack_id, nil}
            }

          {:error, reason} ->
            %Message{data: %{error: reason}, acknowledger: {__MODULE__, :ack_id, nil}}
        end
      end)

    {:noreply, messages, {remaining_files, library_id}}
  end

  def ack(:ack_id, _successful, _failed) do
    # Logger.debug("Acknowledged successful messages: #{length(successful)}")
    # Logger.debug("Acknowledged failed messages: #{length(failed)}")
    :ok
  end

  defp get_file_list(base_path) do
    File.ls!(base_path)
    |> Enum.map(&Path.join(base_path, &1))
    |> Enum.flat_map(&expand_path/1)
    |> Enum.filter(&video_file?/1)
  end

  defp expand_path(path) do
    case File.dir?(path) do
      true ->
        get_file_list(path)

      false ->
        [path]
    end
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
