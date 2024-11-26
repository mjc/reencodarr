defmodule Reencodarr.Pipeline.Scanner.Video.Producer do
  use GenStage
  alias Broadway.Message

  require Logger

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    file_stream = get_file_stream(path)
    {:producer, {file_stream, MapSet.new()}}
  end

  def handle_demand(demand, {file_stream, processed_files}) when demand > 0 do
    {events, remaining_stream} = Enum.split(file_stream, demand)

    {new_messages, new_processed_files} =
      events
      |> Enum.reject(&MapSet.member?(processed_files, &1))
      |> Enum.map_reduce(processed_files, fn file, acc ->
        {create_message(file), MapSet.put(acc, file)}
      end)

    {:noreply, new_messages, {remaining_stream, new_processed_files}}
  end

  def ack(:ack_id, _successful, _failed), do: :ok

  defp get_file_stream(base_path) do
    Stream.resource(
      fn -> [base_path] end,
      &next_file/1,
      fn _ -> :ok end
    )
    |> Stream.flat_map(&expand_path/1)
    |> Stream.filter(&video_file?/1)
  end

  defp next_file([]), do: {:halt, []}

  defp next_file([path | rest]) do
    case File.ls(path) do
      {:ok, files} ->
        expanded_paths = Enum.map(files, &Path.join(path, &1))
        {expanded_paths, rest ++ expanded_paths}

      {:error, _} ->
        {[], rest}
    end
  end

  defp expand_path(path) do
    if File.dir?(path) do
      get_file_stream(path)
    else
      [path]
    end
  end

  defp create_message(file_path) do
    case get_size(file_path) do
      {:ok, size} ->
        %Message{
          data: %{path: file_path, size: size},
          acknowledger: {__MODULE__, :ack_id, nil}
        }

      {:error, reason} ->
        %Message{data: %{error: reason}, acknowledger: {__MODULE__, :ack_id, nil}}
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
    ext in [".mp4", ".mkv", ".avi", ".mov"]
  end
end
