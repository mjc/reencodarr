defmodule Reencodarr.Pipeline.Scanner.Video do
  use Broadway

  alias Broadway.Message

  require Logger

  def start_link(opts) do
    path = Keyword.get(opts, :path, "/default/path")
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {__MODULE__.Producer, [path: path]},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 10]
      ]
    )
  end

  def handle_message(_, %Message{data: data} = message, _) do
    # Logger.debug("Processing video file: #{file_path}")

    case Reencodarr.Media.upsert_video(data) do
      {:ok, _video} -> message
      {:error, reason} ->
        Logger.error("Failed to process video #{data.path}: #{inspect(reason)}")
        Message.update_data(message, fn _ -> {:error, reason} end)
    end
  end

  defmodule Producer do
    use GenStage
    alias Broadway.Message

    require Logger

    def start_link(_opts) do
      GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    def init(opts) do
      path = Keyword.fetch!(opts, :path)
      file_stream = get_file_stream(path)
      {:producer, {file_stream, nil}}
    end

    def handle_demand(demand, {file_stream, nil}) when demand > 0 do
      library_id = get_library_id(file_stream)
      handle_demand(demand, {file_stream, library_id})
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

    defp get_library_id(file_stream) do
      file_stream
      |> Enum.at(0)
      |> case do
        nil -> {:error, :library_not_found}
        file_path ->
          libraries = Reencodarr.Media.list_libraries()
          case Enum.find(libraries, fn library -> String.starts_with?(file_path, library.path) end) do
            nil -> {:error, :library_not_found}
            library -> library.id
          end
      end
    end

    defp video_file?(file_path) do
      ext = Path.extname(file_path) |> String.downcase()
      Enum.member?([".mp4", ".mkv", ".avi", ".mov"], ext)
    end
  end
end
