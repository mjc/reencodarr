defmodule ReencodarrWeb.RulesLive do
  @moduledoc """
  Live dashboard for explaining how Reencodarr's encoding rules work.

  ## Features:
  - Interactive rule explanations
  - Example configurations
  - Parameter descriptions
  - Video format guidelines

  ## Architecture Notes:
  - Modern Dashboard V2 UI with card-based layout
  - Section-based navigation for easy browsing
  - Real-time content switching without page reload
  """

  use ReencodarrWeb, :live_view

  import ReencodarrWeb.RulesLive.Sections

  require Logger

  @valid_sections ~w(overview video_rules audio_rules hdr_support resolution_scaling helper_rules crf_search command_examples)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :selected_section, :overview)}
  end

  @impl true
  def handle_event("select_section", %{"section" => section}, socket) do
    section_atom = String.to_existing_atom(section)

    if section_atom in @valid_sections do
      {:noreply, assign(socket, :selected_section, section_atom)}
    else
      {:noreply, socket}
    end
  rescue
    ArgumentError ->
      {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 p-6">
      <div class="max-w-7xl mx-auto space-y-6">
        <!-- Header -->
        <div>
          <h1 class="text-3xl font-bold text-white">Encoding Rules Documentation</h1>
          <p class="text-gray-400">
            Learn how Reencodarr automatically optimizes video encoding
          </p>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
          <!-- Sidebar Navigation -->
          <div class="lg:col-span-1">
            <.rules_navigation selected_section={@selected_section} />
          </div>
          
    <!-- Main Content -->
          <div class="lg:col-span-3">
            <%= case @selected_section do %>
              <% :overview -> %>
                <.rules_overview />
              <% :video_rules -> %>
                <.video_rules_section />
              <% :audio_rules -> %>
                <.audio_rules_section />
              <% :hdr_support -> %>
                <.hdr_rules_section />
              <% :resolution_scaling -> %>
                <.resolution_rules_section />
              <% :helper_rules -> %>
                <.helper_rules_section />
              <% :crf_search -> %>
                <.crf_search_section />
              <% :command_examples -> %>
                <.command_examples_section />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
