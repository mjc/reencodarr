defmodule Reencodarr.Dashboard.State do
  @moduledoc """
  Single source of truth for dashboard state.

  Subscribes to pipeline PubSub channels, maintains state that survives
  page refreshes, and broadcasts consolidated state changes on
  `state_channel()` so DashboardLive doesn't need to independently
  process the same raw events.
  """

  use GenServer
  require Logger

  alias Reencodarr.Dashboard.Events

  @state_channel "dashboard:state"

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

  @doc """
  Returns the PubSub channel that state change broadcasts are sent on.

  DashboardLive subscribes to this channel to receive consolidated
  `{:dashboard_state_changed, state}` messages instead of independently
  processing raw pipeline events.
  """
  def state_channel, do: @state_channel

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to dashboard events
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

    # Subscribe to pipeline state changes (same channels as DashboardLive)
    # PipelineStateMachine broadcasts on these via Events.pipeline_state_changed/3
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")

    {:ok, @default_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # CRF Search Events

  @impl true
  def handle_info({:crf_search_started, video}, state) do
    service_status = Map.put(state.service_status, :crf_searcher, :processing)

    state = %{
      state
      | crf_search_video: video,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: :none,
        service_status: service_status
    }

    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_vmaf_result, result}, state) do
    results =
      state.crf_search_results
      |> update_or_append(result, :crf)
      |> Enum.sort_by(& &1.crf)

    state = %{state | crf_search_results: results}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_encoding_sample, sample}, state) do
    state = %{state | crf_search_sample: sample}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_progress, progress}, state) do
    state = %{state | crf_progress: progress}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_completed, _data}, state) do
    service_status = Map.put(state.service_status, :crf_searcher, :idle)

    state = %{
      state
      | crf_search_video: nil,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: :none,
        service_status: service_status
    }

    broadcast_state(state)
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

    service_status = Map.put(state.service_status, :encoder, :processing)

    state = %{
      state
      | encoding_video: encoding_video,
        encoding_vmaf: encoding_vmaf,
        encoding_progress: %{percent: 0, video_id: data.video_id, filename: data.filename},
        service_status: service_status
    }

    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:encoding_progress, progress}, state) do
    service_status = Map.put(state.service_status, :encoder, :processing)
    state = %{state | encoding_progress: progress, service_status: service_status}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:encoding_completed, _data}, state) do
    service_status = Map.put(state.service_status, :encoder, :idle)

    state = %{
      state
      | encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none,
        service_status: service_status
    }

    broadcast_state(state)
    {:noreply, state}
  end

  # Service Status Events from PipelineStateMachine
  # Accepts only valid pipeline states defined in PipelineStateMachine

  @pipeline_services [:analyzer, :crf_searcher, :encoder]

  @impl true
  def handle_info({service, status}, state)
      when service in @pipeline_services and is_atom(status) do
    service_status = Map.put(state.service_status, service, status)
    state = %{state | service_status: service_status}
    broadcast_state(state)
    {:noreply, state}
  end

  # Catch-all for unknown messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Dashboard.State received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Helpers

  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, @state_channel, {:dashboard_state_changed, state})
  end

  # Helper to upsert a result in a list by key
  defp update_or_append(list, new_item, key) do
    key_value = Map.get(new_item, key)

    case Enum.find_index(list, &(Map.get(&1, key) == key_value)) do
      nil -> [new_item | list]
      index -> List.replace_at(list, index, new_item)
    end
  end
end
