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
    details = []

    details =
      if CrfSearchProgress.has_crf?(progress) do
        ["CRF: #{ProgressHelpers.format_number(progress.crf)}" | details]
      else
        details
      end

    details =
      if CrfSearchProgress.has_score?(progress) do
        ["VMAF Score: #{ProgressHelpers.format_number(progress.score)} (Target: 95)" | details]
      else
        details
      end

    details =
      if CrfSearchProgress.has_percent?(progress) do
        ["Progress: #{ProgressHelpers.format_percent(progress.percent)}" | details]
      else
        details
      end

    details =
      if CrfSearchProgress.has_fps?(progress) do
        ["FPS: #{ProgressHelpers.format_number(progress.fps)}" | details]
      else
        details
      end

    details =
      if CrfSearchProgress.has_eta?(progress) do
        ["ETA: #{ProgressHelpers.format_duration(progress.eta)}" | details]
      else
        details
      end

    Enum.reverse(details)
  end
end
