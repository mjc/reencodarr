defmodule ReencodarrWeb.StatisticsComponent do
  @moduledoc """
  Modern statistics display component using LCARS theming.

  Converted to function component for better performance since this only 
  displays static data - LiveComponent overhead is unnecessary.
  """

  use Phoenix.Component
  import ReencodarrWeb.LcarsComponents
  alias Reencodarr.Core.Time

  attr :stats, :map, required: true, doc: "Statistics data from the database"
  attr :timezone, :string, required: true, doc: "User's timezone for date formatting"

  def statistics(assigns) do
    ~H"""
    <.lcars_panel title="DATABASE STATISTICS" color="cyan">
      <div class="space-y-3">
        <.stat_row
          label="Most Recent Video Update"
          value={format_time(@stats.most_recent_video_update, @timezone)}
          tooltip="Last time any video was updated in the database"
        />

        <.stat_row
          label="Most Recent Inserted Video"
          value={format_time(@stats.most_recent_inserted_video, @timezone)}
          tooltip="Last time a new video was added"
        />

        <.stat_row
          label="Total VMAFs"
          value={@stats.total_vmafs}
        />

        <.stat_row
          label="Chosen VMAFs Count"
          value={@stats.chosen_vmafs_count}
        />

        <.stat_row
          label="Lowest Chosen VMAF %"
          value={@stats.lowest_vmaf_percent || "N/A"}
          tooltip="Lowest VMAF percentage chosen for any video"
        />
      </div>
    </.lcars_panel>
    """
  end

  # Modern statistic row component with optional tooltip
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tooltip, :string, default: nil

  defp stat_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between group">
      <div class="flex items-center space-x-1 text-orange-300 text-sm">
        <span>{@label}</span>
        <%= if @tooltip do %>
          <span
            class="text-xs text-orange-500 cursor-help group-hover:text-orange-400 transition-colors"
            title={@tooltip}
            aria-label={@tooltip}
          >
            ?
          </span>
        <% end %>
      </div>
      <div class="text-orange-100 text-sm font-mono">
        {@value}
      </div>
    </div>
    """
  end

  defp format_time(nil, _timezone), do: "N/A"
  defp format_time(datetime, timezone), do: Time.relative_time_with_timezone(datetime, timezone)
end
