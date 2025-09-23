defmodule ReencodarrWeb.DashboardLive do
  @moduledoc """
  Live dashboard for Reencodarr overview with optimized memory usage.

  ## Overview Dashboard Features:
  - Real-time metrics and system status
  - Queue monitoring and management
  - Operations control panel
  - Manual scanning interface

  ## Architecture Notes:
  - Uses shared LCARS components for consistent UI
  - Leverages presenter pattern for optimized data flow
  - Implements telemetry for real-time updates
  - Memory optimized with selective state updates
  """

  use ReencodarrWeb, :live_view

  require Logger

  alias ReencodarrWeb.Dashboard.Presenter
  alias ReencodarrWeb.DashboardLiveHelpers
  import ReencodarrWeb.LcarsComponents
  import ReencodarrWeb.DashboardComponents

  # Modern LiveView lifecycle management
  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> DashboardLiveHelpers.standard_mount_setup(fn s ->
        s
        |> setup_telemetry()
        |> assign_initial_state()
        |> setup_streams()
      end)
      |> maybe_load_initial_data()

    {:ok, socket}
  end

  # Private helper for better separation of concerns
  defp assign_initial_state(socket) do
    socket
    |> assign(:dashboard_data, nil)
    |> assign(:loading_queues, false)
  end

  defp maybe_load_initial_data(socket) do
    if connected?(socket) do
      send(self(), :load_initial_data)
    end

    socket
  end

  # Modern event handling with pattern matching and better error handling

  @impl Phoenix.LiveView
  def handle_info(:load_initial_data, socket) do
    with {:ok, full_state} <- get_dashboard_state(),
         {:ok, dashboard_data} <- present_state(full_state, socket.assigns.timezone) do
      socket =
        socket
        |> assign(:dashboard_data, dashboard_data)
        |> assign(:loading_queues, false)
        |> update_queue_streams(dashboard_data.queues)

      {:noreply, socket}
    else
      error ->
        {:noreply, log_and_flash_error(socket, error, :initial_data)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:telemetry_event, state}, socket) do
    Logger.debug("Received telemetry event", analyzer_progress: state.analyzer_progress)

    case present_state(state, socket.assigns.timezone) do
      {:ok, dashboard_data} ->
        socket =
          socket
          |> assign(:dashboard_data, dashboard_data)
          |> update_queue_streams(dashboard_data.queues)

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Dashboard telemetry event error: #{inspect(error)}")
        Logger.debug("Received state: #{inspect(state)}")
        # Don't crash the LiveView, just ignore the bad event
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:update_stardate, socket) do
    {:noreply, DashboardLiveHelpers.handle_stardate_update(socket)}
  end

  # Modern event handling with better validation and error handling

  @impl Phoenix.LiveView
  def handle_event("set_timezone", params, socket) do
    case extract_timezone(params) do
      {:ok, timezone} ->
        Logger.debug("Setting timezone to #{timezone}")

        with {:ok, current_state} <- get_dashboard_state(),
             {:ok, dashboard_data} <- present_state(current_state, timezone) do
          socket =
            socket
            |> DashboardLiveHelpers.handle_timezone_change(timezone)
            |> assign(:dashboard_data, dashboard_data)

          {:noreply, socket}
        else
          error -> handle_error_with_flash(socket, error, :timezone)
        end

      {:error, reason} ->
        Logger.warning("Invalid timezone parameter: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Invalid timezone")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ["broadway", "failures"] do
    path = "/" <> tab
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("switch_tab", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("manual_scan", params, socket) do
    case extract_scan_path(params) do
      {:ok, path} ->
        Logger.info("Starting manual scan for path: #{path}")
        Reencodarr.ManualScanner.scan(path)
        {:noreply, put_flash(socket, :info, "Manual scan started for #{path}")}

      {:error, reason} ->
        Logger.warning("Invalid scan path: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Invalid scan path")}
    end
  end

  # Modern render function with better organization
  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.lcars_page_frame
      title="REENCODARR OPERATIONS - OVERVIEW"
      current_page={:overview}
      current_stardate={@current_stardate}
    >
      <.dashboard_content
        dashboard_data={@dashboard_data}
        loading_queues={@loading_queues}
        streams={@streams}
      />
    </.lcars_page_frame>
    """
  end

  # Extract dashboard content to a separate component for better organization
  defp dashboard_content(%{dashboard_data: nil} = assigns) do
    ~H"""
    <div class="text-center text-lcars-orange-300 py-8">
      <div class="animate-pulse">
        <div class="text-lg">⚡ Loading dashboard data...</div>
      </div>
    </div>
    """
  end

  defp dashboard_content(assigns) do
    ~H"""
    <div class="space-y-4 sm:space-y-6">
      <.metrics_grid metrics={@dashboard_data.metrics} />
      <.operations_panel status={@dashboard_data.status} />

      <%= if @loading_queues do %>
        <div class="text-center text-lcars-orange-300 py-4 text-sm">
          <span class="animate-pulse flex items-center justify-center gap-2">
            <span class="inline-block w-2 h-2 bg-current rounded-full animate-bounce"></span>
            <span class="inline-block w-2 h-2 bg-current rounded-full animate-bounce [animation-delay:0.1s]">
            </span>
            <span class="inline-block w-2 h-2 bg-current rounded-full animate-bounce [animation-delay:0.2s]">
            </span>
            <span class="ml-2">Loading queue data...</span>
          </span>
        </div>
      <% end %>

      <.queues_section queues={@dashboard_data.queues} streams={@streams || %{}} />

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6">
        <.control_panel status={@dashboard_data.status} stats={@dashboard_data.stats} />
        <.manual_scan_section />
      </div>
    </div>
    """
  end

  # Modern lifecycle management with proper cleanup
  @impl Phoenix.LiveView
  def terminate(_reason, socket) do
    if connected?(socket) do
      :telemetry.detach("dashboard-#{inspect(self())}")
    end

    :ok
  end

  # Private helper functions with better error handling

  defp setup_telemetry(socket) do
    if connected?(socket) do
      :telemetry.attach_many(
        "dashboard-#{inspect(self())}",
        [[:reencodarr, :dashboard, :state_updated]],
        &__MODULE__.handle_telemetry_event/4,
        %{live_view_pid: self()}
      )
    end

    socket
  end

  defp setup_streams(socket) do
    socket
    |> stream(:crf_search_queue, [])
    |> stream(:encoding_queue, [])
    |> stream(:analyzer_queue, [])
  end

  # Improved stream update with better error handling
  defp update_queue_streams(socket, queues) do
    crf_search_items = generate_stream_items(queues.crf_search.files, "crf")
    encoding_items = generate_stream_items(queues.encoding.files, "enc")
    analyzer_items = generate_stream_items(queues.analyzer.files, "ana")

    socket
    |> stream(:crf_search_queue, crf_search_items, reset: true)
    |> stream(:encoding_queue, encoding_items, reset: true)
    |> stream(:analyzer_queue, analyzer_items, reset: true)
  end

  defp generate_stream_items(files, prefix) when is_list(files) do
    files
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      path_hash = :erlang.phash2(item.path)
      Map.put(item, :id, "#{prefix}-#{path_hash}-#{index}")
    end)
  end

  defp generate_stream_items(_, _), do: []

  # State retrieval functions
  defp get_dashboard_state do
    case Reencodarr.DashboardState.initial_with_queues() do
      result when is_struct(result) -> {:ok, result}
      error -> {:error, {:dashboard_state_error, error}}
    end
  end

  defp present_state(state, timezone) do
    case Presenter.present(state, timezone) do
      result when is_map(result) -> {:ok, result}
      error -> {:error, {:presenter_error, error}}
    end
  end

  # Parameter extraction functions with validation
  defp extract_timezone(%{"timezone" => tz}) when is_binary(tz) and tz != "", do: {:ok, tz}
  defp extract_timezone(params), do: {:error, {:invalid_timezone, params}}

  defp extract_scan_path(%{"path" => path}) when is_binary(path) and path != "",
    do: {:ok, String.trim(path)}

  defp extract_scan_path(params), do: {:error, {:invalid_path, params}}

  # Error handling helpers for more idiomatic flash messages
  defp log_and_flash_error(socket, error, context) do
    message = error_message(error, context)
    Logger.warning("#{context} error: #{inspect(error)}")
    put_flash(socket, :error, message)
  end

  defp handle_error_with_flash(socket, error, context) do
    {:noreply, log_and_flash_error(socket, error, context)}
  end

  defp error_message(_error, :timezone), do: "Failed to update timezone"
  defp error_message(_error, :scan_path), do: "Invalid scan path"
  defp error_message(_error, :initial_data), do: "Failed to load dashboard data"
  defp error_message(error, :general), do: "An error occurred: #{inspect(error)}"

  # Modern telemetry event handler with better structure and logging
  @doc """
  Handles telemetry events for dashboard state updates.

  This function is called by the telemetry system when dashboard
  state changes occur. It forwards the state to the LiveView process
  for real-time UI updates.
  """
  def handle_telemetry_event(
        [:reencodarr, :dashboard, :state_updated] = event,
        _measurements,
        %{state: state} = metadata,
        %{live_view_pid: pid} = config
      ) do
    with {:ok, merged_state} <- merge_default_state(state),
         {:ok, _} <- validate_telemetry_state(merged_state),
         :ok <- send_telemetry_update(pid, merged_state) do
      log_telemetry_success(event, merged_state)
      :ok
    else
      {:error, reason} ->
        log_telemetry_error(event, reason, metadata, config)
        :ok
    end
  end

  # Fallback for other telemetry events
  def handle_telemetry_event(event, measurements, metadata, config) do
    Logger.debug([
      "Unhandled telemetry event: ",
      inspect(event),
      " - measurements: ",
      inspect(measurements),
      " - metadata: ",
      inspect(Map.keys(metadata)),
      " - config: ",
      inspect(Map.keys(config))
    ])

    :ok
  end

  # Helper functions for telemetry handling
  defp merge_default_state(state) do
    merged = Map.merge(%{syncing: false, analyzer_progress: %{}}, state)
    {:ok, merged}
  end

  defp send_telemetry_update(pid, state) when is_pid(pid) do
    send(pid, {:telemetry_event, state})
    :ok
  end

  defp send_telemetry_update(_invalid_pid, _state), do: {:error, :invalid_pid}

  defp log_telemetry_success(event, %{syncing: syncing, analyzer_progress: analyzer_progress}) do
    Logger.debug([
      "DashboardLive telemetry event received",
      " - event: ",
      inspect(event),
      " - syncing: ",
      inspect(syncing),
      " - analyzer_progress: ",
      inspect(analyzer_progress)
    ])
  end

  defp log_telemetry_error(event, reason, metadata, config) do
    Logger.warning([
      "Invalid telemetry state received, skipping update",
      " - reason: ",
      inspect(reason),
      " - event: ",
      inspect(event),
      " - metadata: ",
      inspect(metadata),
      " - config: ",
      inspect(config)
    ])
  end

  # Validates telemetry state structure
  defp validate_telemetry_state(%{syncing: _, analyzing: _, encoding: _, crf_searching: _}),
    do: :ok

  defp validate_telemetry_state(state) when is_map(state) do
    required_keys = [:syncing, :analyzing, :encoding, :crf_searching]
    {:error, {:missing_keys, required_keys -- Map.keys(state)}}
  end

  defp validate_telemetry_state(state), do: {:error, {:invalid_type, typeof(state)}}

  defp typeof(value) when is_map(value), do: :map
  defp typeof(value) when is_list(value), do: :list
  defp typeof(value) when is_atom(value), do: :atom
  defp typeof(_), do: :unknown
end
