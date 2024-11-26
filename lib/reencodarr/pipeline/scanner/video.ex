defmodule Reencodarr.Pipeline.Scanner.Video do
  use Broadway

  alias Broadway.Message

  require Logger

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)

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

  @impl true
  def handle_message(_, %Message{data: %{path: path} = data} = message, _) do
    {mediainfo, _status} = System.cmd("mediainfo", ["--Output=JSON", path])

    case Reencodarr.Media.upsert_video(Map.merge(data, %{mediainfo: Jason.decode!(mediainfo)})) do
      {:ok, _video} ->
        message

      {:error, reason} ->
        Logger.error("Failed to process video #{path}: #{inspect(reason)}")
        Message.update_data(message, fn _ -> %{error: reason} end)
    end
  end
end
