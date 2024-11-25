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

  def handle_message(_, %Message{data: file_path} = message, _) do
    # Logger.debug("Processing video file: #{file_path}")

    case File.stat(file_path) do
      {:ok, %File.Stat{size: size}} ->
        case Reencodarr.Media.upsert_video(%{path: file_path, size: size}) do
          {:ok, _video} -> message
          {:error, changeset} ->
            Logger.error("Failed to upsert video #{file_path} into database: #{inspect(changeset.errors)}")
            Message.update_data(message, fn _ -> {:error, changeset.errors} end)
        end
      {:error, reason} ->
        Logger.error("Failed to get file size for #{file_path}: #{reason}")
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
      {:producer, file_stream}
    end

    def handle_demand(demand, file_stream) when demand > 0 do
      events = Enum.take(file_stream, demand)
      messages = Enum.map(events, &%Message{data: &1, acknowledger: {__MODULE__, :ack_id, nil}})
      {:noreply, messages, file_stream}
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

    defp video_file?(file_path) do
      ext = Path.extname(file_path) |> String.downcase()
      Enum.member?([".mp4", ".mkv", ".avi", ".mov"], ext)
    end
  end
end
