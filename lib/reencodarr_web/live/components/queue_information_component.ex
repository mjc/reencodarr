defmodule ReencodarrWeb.QueueInformationComponent do
  @moduledoc """
  Modern queue information component using LCARS theming.

  Converted to function component for better performance since this only 
  displays static data - LiveComponent overhead is unnecessary.
  """

  use Phoenix.Component
  import ReencodarrWeb.LcarsComponents

  attr :stats, :map, required: true, doc: "Queue statistics including counts for each queue type"

  def queue_information(assigns) do
    ~H"""
    <.lcars_panel title="QUEUE STATUS" color="green">
      <div class="space-y-3">
        <.lcars_stat_row
          label="CRF Searches in Queue"
          value={get_queue_count(@stats, :crf_searches)}
        />

        <.lcars_stat_row
          label="Encodes in Queue"
          value={get_queue_count(@stats, :encodes)}
        />

        <.lcars_stat_row
          label="Analysis Queue"
          value={get_queue_count(@stats, :analysis)}
        />
      </div>
    </.lcars_panel>
    """
  end

  # Safely extract queue count with fallback
  defp get_queue_count(%{queue_length: queue_length}, key) when is_map(queue_length) do
    Map.get(queue_length, key, 0)
  end

  defp get_queue_count(_, _), do: "N/A"
end
