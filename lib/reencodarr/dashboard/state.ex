defmodule Reencodarr.Dashboard.State do
  @moduledoc """
  Persistent state manager for the dashboard.

  Subscribes to the same PubSub channels as DashboardLive and maintains
  a snapshot of active work state that survives page refreshes.
  """

  use GenServer
  require Logger

  alias Reencodarr.Dashboard.Events

  @default_state %{
    crf_search_video: nil,
    crf_search_results: [],
    crf_search_sample: nil,
    crf_progress: :none,
    encoding_video: nil,
    encoding_vmaf: nil,
    encoding_progress: :none,
    service_status: %{
      analyzer: :idle,
      crf_searcher: :idle,
      encoder: :idle
    }
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current dashboard state.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to dashboard events
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

    # Subscribe to pipeline status channels
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer:status")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher:status")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder:status")

    {:ok, @default_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # CRF Search Events

  @impl true
  def handle_info({:crf_search_started, video}, state) do
    state = %{
      state
      | crf_search_video: video,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: :none
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_vmaf_result, result}, state) do
    results =
      state.crf_search_results
      |> update_or_append(result, :crf)
      |> Enum.sort_by(& &1.crf)

    state = %{state | crf_search_results: results}
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_encoding_sample, sample}, state) do
    state = %{state | crf_search_sample: sample}
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_progress, progress}, state) do
    state = %{state | crf_progress: progress}
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_completed, _data}, state) do
    state = %{
      state
      | crf_search_video: nil,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: :none
    }

    {:noreply, state}
  end

  # Encoding Events

  @impl true
  def handle_info({:encoding_started, data}, state) do
    encoding_video = %{
      video_id: data.video_id,
      filename: data.filename,
      video_size: data[:video_size],
      width: data[:width],
      height: data[:height],
      hdr: data[:hdr],
      video_codecs: data[:video_codecs]
    }

    encoding_vmaf = %{
      crf: data[:crf],
      vmaf_score: data[:vmaf_score],
      predicted_percent: data[:predicted_percent],
      predicted_savings: data[:predicted_savings]
    }

    state = %{
      state
      | encoding_video: encoding_video,
        encoding_vmaf: encoding_vmaf,
        encoding_progress: %{percent: 0, video_id: data.video_id, filename: data.filename}
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:encoding_progress, progress}, state) do
    state = %{state | encoding_progress: progress}
    {:noreply, state}
  end

  @impl true
  def handle_info({:encoding_completed, _data}, state) do
    state = %{
      state
      | encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none
    }

    {:noreply, state}
  end

  # Service Status Events

  @impl true
  def handle_info({:analyzer, status}, state) do
    service_status = Map.put(state.service_status, :analyzer, status)
    state = %{state | service_status: service_status}
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_searcher, status}, state) do
    service_status = Map.put(state.service_status, :crf_searcher, status)
    state = %{state | service_status: service_status}
    {:noreply, state}
  end

  @impl true
  def handle_info({:encoder, status}, state) do
    service_status = Map.put(state.service_status, :encoder, status)
    state = %{state | service_status: service_status}
    {:noreply, state}
  end

  # Catch-all for unknown messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Dashboard.State received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Helpers

  # Helper to upsert a result in a list by key (same as dashboard_live.ex:1291)
  defp update_or_append(list, new_item, key) do
    key_value = Map.get(new_item, key)

    case Enum.find_index(list, &(Map.get(&1, key) == key_value)) do
      nil -> [new_item | list]
      index -> List.replace_at(list, index, new_item)
    end
  end
end
