defmodule ReencodarrWeb.ManualScanComponent do
  @moduledoc """
  Modern manual scanning component with enhanced UX and validation.

  Provides an interface for manually triggering media file scans with:
  - Input validation and sanitization
  - Visual feedback and loading states
  - Accessibility improvements
  - Better error handling
  """

  use Phoenix.LiveComponent
  require Logger

  @impl Phoenix.LiveComponent
  def mount(socket) do
    socket = assign(socket, :scanning, false)
    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-4" role="region" aria-label="Manual file scanning interface">
      <.scan_form scanning={@scanning} myself={@myself} />
      <.scan_instructions />
      <.scan_status :if={@scanning} />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("manual_scan", params, socket) do
    case validate_scan_params(params) do
      {:ok, path} ->
        Logger.info("Starting manual scan for path: #{path}")

        socket = assign(socket, :scanning, true)

        # Start scan asynchronously
        start_scan_operation(path)

        # Notify parent about scan start
        send(self(), {:manual_scan_started, path})

        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("Invalid scan parameters: #{inspect(reason)}")
        send(self(), {:manual_scan_error, reason})
        {:noreply, socket}
    end
  end

  # Public function to update scanning state from parent
  def update_scanning_state(socket, scanning) do
    assign(socket, :scanning, scanning)
  end

  # Parameter validation
  defp validate_scan_params(%{"path" => path}) when is_binary(path) do
    trimmed_path = String.trim(path)

    cond do
      trimmed_path == "" ->
        {:error, :empty_path}

      not String.starts_with?(trimmed_path, "/") ->
        {:error, :relative_path}

      String.contains?(trimmed_path, ["../", ".."]) ->
        {:error, :path_traversal}

      true ->
        {:ok, trimmed_path}
    end
  end

  defp validate_scan_params(params) do
    {:error, {:invalid_params, params}}
  end

  # Async scan operation
  defp start_scan_operation(path) do
    parent_pid = self()

    Task.start(fn ->
      result =
        try do
          Reencodarr.ManualScanner.scan(path)
          :ok
        rescue
          error -> {:error, error}
        end

      # Send result to parent LiveView
      send(parent_pid, {:manual_scan_completed, result})
    end)
  end

  # Modern form component with validation and accessibility
  defp scan_form(assigns) do
    ~H"""
    <form
      phx-submit="manual_scan"
      phx-target={@myself}
      class="space-y-3"
      aria-label="Manual scan form"
    >
      <div class="space-y-2">
        <label
          for="scan-path-input"
          class="block text-orange-300 text-sm font-bold tracking-wide"
        >
          SCAN PATH <span class="text-red-400" aria-label="required">*</span>
        </label>
        <input
          id="scan-path-input"
          type="text"
          name="path"
          placeholder="/path/to/media/files"
          required
          aria-describedby="path-help"
          disabled={@scanning}
          class={[
            "w-full px-4 py-3 bg-gray-800 border-2 rounded font-mono text-orange-400 placeholder-orange-600 transition-all duration-200",
            "focus:outline-none focus:ring-2 focus:ring-yellow-400 focus:border-yellow-400 focus:bg-gray-700",
            if(@scanning, do: "border-yellow-600 opacity-75", else: "border-orange-500")
          ]}
        />
        <p id="path-help" class="text-xs text-orange-400">
          Enter the absolute path to the directory containing media files
        </p>
      </div>

      <button
        type="submit"
        disabled={@scanning}
        aria-describedby="scan-button-help"
        class={[
          "w-full h-12 font-bold tracking-wider rounded transition-all duration-200 hover:brightness-110 flex items-center justify-center space-x-2",
          if(@scanning,
            do: "bg-yellow-600 text-yellow-900 cursor-not-allowed",
            else: "bg-red-500 hover:bg-red-400 text-black"
          )
        ]}
      >
        <%= if @scanning do %>
          <div class="animate-spin rounded-full h-4 w-4 border-b-2 border-yellow-900"></div>
          <span>SCANNING...</span>
        <% else %>
          <span>🔍</span>
          <span>INITIATE SCAN</span>
        <% end %>
      </button>

      <p id="scan-button-help" class="sr-only">
        Starts scanning the specified directory for video files
      </p>
    </form>
    """
  end

  defp scan_instructions(assigns) do
    ~H"""
    <div class="text-xs text-orange-300 tracking-wide space-y-1" role="complementary">
      <h4 class="font-bold text-sm mb-2">SCANNING INSTRUCTIONS:</h4>
      <ul class="space-y-1 list-none">
        <li>• SPECIFY FULL ABSOLUTE PATH TO MEDIA DIRECTORY</li>
        <li>• SCAN WILL PROCESS ALL VIDEO FILES RECURSIVELY</li>
        <li>• OPERATION MAY TAKE SEVERAL MINUTES FOR LARGE DIRECTORIES</li>
        <li>• ENSURE PATH IS ACCESSIBLE AND CONTAINS VIDEO FILES</li>
      </ul>
    </div>
    """
  end

  defp scan_status(assigns) do
    ~H"""
    <div
      class="bg-yellow-900/20 border border-yellow-600 rounded p-3"
      role="status"
      aria-live="polite"
    >
      <div class="flex items-center space-x-2">
        <div class="animate-pulse w-2 h-2 bg-yellow-400 rounded-full"></div>
        <span class="text-yellow-300 text-sm font-medium">
          Manual scan in progress... Please wait.
        </span>
      </div>
    </div>
    """
  end
end
