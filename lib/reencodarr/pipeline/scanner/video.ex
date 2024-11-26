defmodule Reencodarr.Pipeline.Scanner.Video do
  use Broadway

  alias Broadway.Message

  require Logger

  def start_link(opts) do
    path = Keyword.get(opts, :path, "/default/path")

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Reencodarr.Pipeline.Scanner.Video.Producer, [path: path]},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 10, max_demand: 100]
      ]
    )
  end

  def handle_message(_, %Message{data: data} = message, _) do
    # Logger.debug("Processing video file: #{file_path}")

    {mediainfo, status} = System.cmd("mediainfo", ["--Output=JSON", data.path])

    case Reencodarr.Media.upsert_video(Map.merge(data, %{mediainfo: Jason.decode!(mediainfo)})) do
      {:ok, _video} ->
        message

      {:error, reason} ->
        Logger.error("Failed to process video #{data.path}: #{inspect(reason)}")
        Message.update_data(message, fn _ -> {:error, reason} end)
    end
  end
end
