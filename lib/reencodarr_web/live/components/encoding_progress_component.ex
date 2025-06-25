defmodule ReencodarrWeb.EncodingProgressComponent do
  use Phoenix.LiveComponent

  alias Reencodarr.ProgressHelpers

  attr :encoding_progress, :map, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={ReencodarrWeb.ProgressDetailComponent}
        id={"#{@id}-detail"}
        title={if @encoding_progress.filename != :none, do: "Encoding:", else: nil}
        subtitle={if @encoding_progress.filename != :none, do: ProgressHelpers.format_filename(@encoding_progress.filename), else: nil}
        details={build_details(@encoding_progress)}
        progress_percent={if @encoding_progress.filename != :none, do: @encoding_progress.percent, else: nil}
        progress_color="indigo"
        inactive_message="No encoding in progress"
      />
    </div>
    """
  end

  defp build_details(progress) do
    if progress.filename != :none do
      [
        "FPS: #{ProgressHelpers.format_value(progress.fps)}",
        "ETA: #{ProgressHelpers.format_duration(progress.eta)}"
      ]
      |> Enum.reject(&(&1 =~ "N/A"))
    else
      []
    end
  end
end
