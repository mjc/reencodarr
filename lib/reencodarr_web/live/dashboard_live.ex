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
    with {:ok, essential_state} <- get_safe_essential_state(),
         {:ok, dashboard_data} <- present_state(essential_state, socket.assigns.timezone) do
      socket =
        socket
        |> assign(:dashboard_data, dashboard_data)
        |> assign(:loading_queues, true)

      # Async queue loading with brief delay for better UX
      Process.send_after(self(), :load_queue_data, 100)
      {:noreply, socket}
    else
      error ->
        Logger.warning("Failed to load initial data: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to load dashboard data")}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:load_queue_data, socket) do
    with {:ok, full_state} <- get_safe_full_state(),
         {:ok, dashboard_data} <- present_state(full_state, socket.assigns.timezone) do
      socket =
        socket
        |> assign(:dashboard_data, dashboard_data)
        |> assign(:loading_queues, false)
        |> update_queue_streams(dashboard_data.queues)

      {:noreply, socket}
    else
      error ->
        Logger.warning("Failed to load queue data: #{inspect(error)}")
        {:noreply, assign(socket, :loading_queues, false)}
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

        with {:ok, current_state} <- get_safe_full_state(),
             {:ok, dashboard_data} <- present_state(current_state, timezone) do
          socket =
            socket
            |> DashboardLiveHelpers.handle_timezone_change(timezone)
            |> assign(:dashboard_data, dashboard_data)

          {:noreply, socket}
        else
          error ->
            Logger.warning("Failed to update timezone: #{inspect(error)}")
            {:noreply, put_flash(socket, :error, "Failed to update timezone")}
        end

      {:error, reason} ->
        Logger.warning("Invalid timezone parameter: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Invalid timezone")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    # Modern navigation with pattern matching
    destination =
      case tab do
        "broadway" -> "/broadway"
        "failures" -> "/failures"
        _ -> nil
      end

    case destination do
      nil -> {:noreply, socket}
      path -> {:noreply, push_navigate(socket, to: path)}
    end
  end

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

      <.loading_indicator :if={@loading_queues} />

      <.queues_section queues={@dashboard_data.queues} streams={@streams || %{}} />

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6">
        <.control_panel status={@dashboard_data.status} stats={@dashboard_data.stats} />
        <.manual_scan_section />
      </div>
    </div>
    """
  end

  defp loading_indicator(assigns) do
    ~H"""
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
  rescue
    error ->
      Logger.warning("Failed to update queue streams: #{inspect(error)}")
      socket
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

  # Safe state retrieval functions
  defp get_safe_essential_state do
    {:ok, DashboardLiveHelpers.get_essential_state()}
  rescue
    error -> {:error, error}
  end

  defp get_safe_full_state do
    {:ok, DashboardLiveHelpers.get_initial_state()}
  rescue
    error -> {:error, error}
  end

  defp present_state(state, timezone) do
    {:ok, Presenter.present(state, timezone)}
  rescue
    error -> {:error, error}
  end

  # Parameter extraction functions with validation
  defp extract_timezone(%{"timezone" => tz}) when is_binary(tz) and tz != "" do
    {:ok, tz}
  end

  defp extract_timezone(params) do
    {:error, {:invalid_timezone, params}}
  end

  defp extract_scan_path(%{"path" => path}) when is_binary(path) and path != "" do
    {:ok, String.trim(path)}
  end

  defp extract_scan_path(params) do
    {:error, {:invalid_path, params}}
  end

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
    Logger.debug([
      "DashboardLive telemetry event received",
      " - event: ",
      inspect(event),
      " - syncing: ",
      inspect(Map.get(state, :syncing, false)),
      " - analyzer_progress: ",
      inspect(Map.get(state, :analyzer_progress, %{}))
    ])

    # Validate state structure before forwarding
    case validate_telemetry_state(state) do
      :ok ->
        send(pid, {:telemetry_event, state})

      {:error, reason} ->
        Logger.warning([
          "Invalid telemetry state received, skipping update",
          " - reason: ",
          inspect(reason),
          " - state keys: ",
          inspect(Map.keys(state))
        ])
    end

    :ok
  rescue
    error ->
      Logger.error([
        "Failed to handle telemetry event: ",
        inspect(error),
        " - event: ",
        inspect(event),
        " - metadata: ",
        inspect(metadata),
        " - config: ",
        inspect(config)
      ])

      :ok
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

  # Validates telemetry state structure
  defp validate_telemetry_state(state) when is_map(state) do
    required_keys = [:syncing, :analyzing, :encoding, :crf_searching]

    case Enum.all?(required_keys, &Map.has_key?(state, &1)) do
      true -> :ok
      false -> {:error, {:missing_keys, required_keys -- Map.keys(state)}}
    end
  end

  defp validate_telemetry_state(state) do
    {:error, {:invalid_type, typeof(state)}}
  end

  defp typeof(value) when is_map(value), do: :map
  defp typeof(value) when is_list(value), do: :list
  defp typeof(value) when is_atom(value), do: :atom
  defp typeof(_), do: :unknown
end
