defmodule ReencodarrWeb.LcarsComponents do
  @moduledoc """
  Modern LCARS (Library Computer Access/Retrieval System) UI components.

  Provides reusable Star Trek-themed interface components with:
  - Consistent styling and behavior
  - Proper accessibility attributes
  - Modern Phoenix 1.8+ patterns
  - Comprehensive documentation
  """

  use Phoenix.Component

  import ReencodarrWeb.UIHelpers

  @doc """
  Renders the main LCARS page frame with header, navigation, and footer.

  Creates the overall page structure with LCARS styling and provides
  slots for page content.

  ## Attributes

    * `title` (required) - Page title displayed in header
    * `current_page` (required) - Current navigation page for highlighting
    * `current_stardate` (required) - Stardate for footer display

  ## Slots

    * `inner_block` (required) - Main page content
  """
  attr :title, :string, required: true, doc: "Page title for header"
  attr :current_page, :atom, required: true, doc: "Current page for navigation highlighting"
  attr :current_stardate, :float, required: true, doc: "Current stardate for footer"

  slot :inner_block, required: true, doc: "Main page content"

  def lcars_page_frame(assigns) do
    ~H"""
    <div
      id="lcars-dashboard"
      class="min-h-screen bg-black text-orange-400 font-mono lcars-screen lcars-scan-lines"
      phx-hook="TimezoneHook"
      role="main"
    >
      <.lcars_header title={@title} />
      <.lcars_navigation current_page={@current_page} />

      <main class="p-3 sm:p-6 space-y-4 sm:space-y-6" role="main" id="dashboard-main">
        {render_slot(@inner_block)}
        <.lcars_footer current_stardate={@current_stardate} />
      </main>
    </div>
    """
  end

  @doc """
  Renders the LCARS header frame with gradient styling.

  ## Attributes

    * `title` (required) - Title text to display in header
  """
  attr :title, :string, required: true, doc: "Header title text"

  def lcars_header(assigns) do
    ~H"""
    <header
      class="h-12 sm:h-16 bg-gradient-to-r from-orange-500 via-yellow-400 to-red-500 relative lcars-border-gradient"
      role="banner"
    >
      <div
        class="absolute top-0 left-0 w-16 sm:w-32 h-12 sm:h-16 bg-orange-500 lcars-corner-br"
        aria-hidden="true"
      >
      </div>
      <div
        class="absolute top-0 right-0 w-16 sm:w-32 h-12 sm:h-16 bg-red-500 lcars-corner-bl"
        aria-hidden="true"
      >
      </div>

      <div class="flex items-center justify-center h-full px-4">
        <h1 class="text-black text-lg sm:text-2xl lcars-title text-center">
          {@title}
        </h1>
      </div>
    </header>
    """
  end

  @doc """
  Renders the LCARS navigation bar with active page highlighting.

  ## Attributes

    * `current_page` (required) - Current page atom for highlighting active state
  """
  attr :current_page, :atom,
    required: true,
    doc: "Current page for active navigation highlighting"

  def lcars_navigation(assigns) do
    ~H"""
    <nav
      class="border-b-2 border-orange-500 bg-gray-900"
      role="navigation"
      aria-label="Main navigation"
    >
      <ul class="flex space-x-1 p-2" role="menubar">
        <.nav_item page={:overview} current={@current_page} path="/" label="OVERVIEW" />
        <.nav_item page={:broadway} current={@current_page} path="/broadway" label="PIPELINE MONITOR" />
        <.nav_item page={:failures} current={@current_page} path="/failures" label="FAILURES" />
        <.nav_item page={:rules} current={@current_page} path="/rules" label="ENCODING RULES" />
      </ul>
    </nav>
    """
  end

  @doc false
  attr :page, :atom, required: true
  attr :current, :atom, required: true
  attr :path, :string, required: true
  attr :label, :string, required: true

  defp nav_item(assigns) do
    active = assigns.page == assigns.current
    assigns = assign(assigns, :active, active)

    ~H"""
    <li role="presentation">
      <%= if @active do %>
        <span class={navigation_link_classes(:active)} role="menuitem" aria-current="page">
          {@label}
        </span>
      <% else %>
        <.link
          navigate={@path}
          class={navigation_link_classes()}
          role="menuitem"
          aria-label={"Navigate to #{@label}"}
        >
          {@label}
        </.link>
      <% end %>
    </li>
    """
  end

  @doc """
  Renders the LCARS footer with stardate display.

  ## Attributes

    * `current_stardate` (required) - Current stardate to display
  """
  attr :current_stardate, :float, required: true, doc: "Current stardate for display"

  def lcars_footer(assigns) do
    ~H"""
    <div class="h-6 sm:h-8 bg-gradient-to-r from-red-500 via-yellow-400 to-orange-500 rounded">
      <div class="flex items-center justify-center h-full">
        <span class="text-black lcars-label text-xs sm:text-sm">
          STARDATE {@current_stardate}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a standard LCARS panel with header and content.
  """
  attr :title, :string, required: true
  attr :color, :string, default: "orange"
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def lcars_panel(assigns) do
    ~H"""
    <div class={["bg-gray-900 border-2 rounded-lg overflow-hidden", border_color(@color), @class]}>
      <div class={["flex items-center px-3 py-2", header_color(@color)]}>
        <span class="text-black font-bold tracking-wider text-sm">
          {@title}
        </span>
      </div>

      <div class="p-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a metric card in LCARS style.
  """
  attr :metric, :map, required: true

  def lcars_metric_card(assigns) do
    ~H"""
    <div class="bg-gray-900 border-2 border-orange-500 lcars-corner-tr lcars-corner-bl overflow-hidden lcars-panel">
      <div class="h-8 sm:h-10 bg-orange-500 flex items-center px-2 sm:px-3 lcars-data-stream">
        <span class="text-black lcars-label text-xs sm:text-sm font-bold truncate">
          {String.upcase(@metric.title)}
        </span>
      </div>

      <div class="p-2 sm:p-3 space-y-2">
        <div class="flex items-center justify-between">
          <span class="text-xl sm:text-2xl">{@metric.icon}</span>
          <span class="text-lg sm:text-2xl lg:text-3xl font-bold lcars-text-primary lcars-title truncate">
            {ReencodarrWeb.DashboardFormatters.format_value(@metric.value)}
          </span>
        </div>

        <div class="lcars-text-secondary lcars-label text-xs sm:text-sm truncate">
          {String.upcase(@metric.subtitle)}
        </div>

        <%= if Map.get(@metric, :progress) do %>
          <div class="space-y-1">
            <div class="h-1.5 sm:h-2 bg-gray-800 lcars-corner-tl lcars-corner-br overflow-hidden">
              <div
                class="h-full lcars-progress transition-all duration-500"
                style={"width: #{@metric.progress}%"}
              >
              </div>
            </div>
            <div class="text-xs lcars-text-secondary text-right lcars-data">
              {@metric.progress}% COMPLETE
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a statistics row in LCARS style.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :small, :boolean, default: false

  def lcars_stat_row(assigns) do
    ~H"""
    <div class="flex justify-between items-center">
      <span class={[
        "lcars-text-secondary lcars-data",
        if(@small, do: "text-xs", else: "text-xs sm:text-sm")
      ]}>
        {@label}
      </span>
      <span class={[
        "lcars-text-primary lcars-data font-bold truncate",
        if(@small, do: "text-xs", else: "text-xs sm:text-sm")
      ]}>
        {@value}
      </span>
    </div>
    """
  end

  # Color helper functions
  defp border_color("orange"), do: "border-orange-500"
  defp border_color("yellow"), do: "border-yellow-400"
  defp border_color("green"), do: "border-green-500"
  defp border_color("red"), do: "border-red-500"
  defp border_color("cyan"), do: "border-cyan-400"
  defp border_color("purple"), do: "border-purple-500"
  defp border_color("blue"), do: "border-blue-500"
  defp border_color(_), do: "border-orange-500"

  defp header_color("orange"), do: "bg-orange-500"
  defp header_color("yellow"), do: "bg-yellow-400"
  defp header_color("green"), do: "bg-green-500"
  defp header_color("red"), do: "bg-red-500"
  defp header_color("cyan"), do: "bg-cyan-400"
  defp header_color("purple"), do: "bg-purple-500"
  defp header_color("blue"), do: "bg-blue-500"
  defp header_color(_), do: "bg-orange-500"
end
