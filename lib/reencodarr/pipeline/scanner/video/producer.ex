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
    {:producer, file_stream}
  end

  def handle_demand(demand, file_stream) when demand > 0 do
    events = Stream.take(file_stream, demand)
    remaining_stream = Stream.drop(file_stream, demand)

    messages =
      Stream.map(events, fn file_path ->
        case get_size(file_path) do
          {:ok, size} ->
            %Message{
              data: %{path: file_path, size: size},
              acknowledger: {__MODULE__, :ack_id, nil}
            }

          {:error, reason} ->
            %Message{data: %{error: reason}, acknowledger: {__MODULE__, :ack_id, nil}}
        end
      end)
      |> Enum.to_list()

    {:noreply, messages, remaining_stream}
  end

  def ack(:ack_id, _successful, _failed) do
    :ok
  end

  defp get_file_stream(base_path) do
    Stream.resource(
      fn -> [base_path] end,
      fn
        [] ->
          {:halt, []}

        [path | rest] ->
          case File.ls(path) do
            {:ok, files} ->
              expanded_paths = Enum.map(files, &Path.join(path, &1))
              {expanded_paths, rest ++ expanded_paths}

            {:error, _} ->
              {[], rest}
          end
      end,
      fn _ -> :ok end
    )
    |> Stream.flat_map(&expand_path/1)
    |> Stream.filter(&video_file?/1)
  end

  defp expand_path(path) do
    if File.dir?(path) do
      get_file_stream(path)
    else
      [path]
    end
  end

  defp get_size(file_path) do
    case File.stat(file_path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp video_file?(file_path) do
    ext = Path.extname(file_path) |> String.downcase()
    Enum.member?([".mp4", ".mkv", ".avi", ".mov"], ext)
  end
end
