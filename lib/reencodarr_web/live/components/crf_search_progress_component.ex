defmodule ReencodarrWeb.CrfSearchProgressComponent do
  use Phoenix.LiveComponent

  alias Reencodarr.Statistics.CrfSearchProgress
  alias Reencodarr.ProgressHelpers

  attr :crf_search_progress, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={ReencodarrWeb.ProgressDetailComponent}
        id={"#{@id}-detail"}
        title={if CrfSearchProgress.has_data?(@crf_search_progress), do: CrfSearchProgress.display_filename(@crf_search_progress), else: nil}
        details={build_details(@crf_search_progress)}
        progress_percent={if CrfSearchProgress.has_percent?(@crf_search_progress), do: @crf_search_progress.percent, else: nil}
        progress_color="purple"
        inactive_message="No CRF search in progress"
      />
    </div>
    """
  end

  defp build_details(progress) do
    [
      {&CrfSearchProgress.has_crf?/1, fn p -> "CRF: #{ProgressHelpers.format_number(p.crf)}" end},
      {&CrfSearchProgress.has_score?/1, fn p -> "VMAF Score: #{ProgressHelpers.format_number(p.score)} (Target: 95)" end},
      {&CrfSearchProgress.has_percent?/1, fn p -> "Progress: #{ProgressHelpers.format_percent(p.percent)}" end},
      {&CrfSearchProgress.has_fps?/1, fn p -> "FPS: #{ProgressHelpers.format_number(p.fps)}" end},
      {&CrfSearchProgress.has_eta?/1, fn p -> "ETA: #{ProgressHelpers.format_duration(p.eta)}" end}
    ]
    |> Enum.filter(fn {has_value?, _formatter} -> has_value?.(progress) end)
    |> Enum.map(fn {_has_value?, formatter} -> formatter.(progress) end)
  end
end
