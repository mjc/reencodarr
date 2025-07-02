defmodule Reencodarr.Dashboard.QueueBuilder do
  @moduledoc """
  Builds queue data structures for the dashboard.

  This module centralizes queue building logic and configuration,
  making it easier to maintain and modify queue presentations.
  """

  alias Reencodarr.Dashboard.QueueItem

  # Queue configurations
  @queue_configs %{
    crf_search: %{
      title: "CRF Search Queue",
      icon: "🔍",
      color: "from-cyan-500 to-blue-500",
      count_key: :crf_searches
    },
    encoding: %{
      title: "Encoding Queue",
      icon: "⚡",
      color: "from-emerald-500 to-teal-500",
      count_key: :encodes
    },
    analyzer: %{
      title: "Analyzer Queue",
      icon: "📊",
      color: "from-purple-500 to-pink-500",
      count_key: :analyzer
    }
  }

  @spec build_queue(atom(), list(), map()) :: map()
  def build_queue(queue_type, files, state)
      when queue_type in [:crf_search, :encoding, :analyzer] do
    config = @queue_configs[queue_type]

    %{
      title: config.title,
      icon: config.icon,
      color: config.color,
      files: normalize_queue_files(files),
      total_count: get_queue_total_count(state, config.count_key)
    }
  end

  @spec normalize_queue_files(list()) :: list()

  defp normalize_queue_files(files) when is_list(files) do
    # Since DashboardState already limits to 10 items, we can process directly
    # Use more efficient Stream operations for better memory usage
    files
    # Start index at 1
    |> Stream.with_index(1)
    |> Enum.map(fn {file, index} -> QueueItem.from_video(file, index) end)
  end

  defp normalize_queue_files(_), do: []

  @spec get_queue_total_count(map(), atom()) :: integer()

  defp get_queue_total_count(state, count_key) do
    case Map.get(state, :stats) do
      %{queue_length: queue_lengths} -> Map.get(queue_lengths, count_key, 0)
      _ -> 0
    end
  end

  @spec queue_configs() :: map()
  def queue_configs, do: @queue_configs
end
