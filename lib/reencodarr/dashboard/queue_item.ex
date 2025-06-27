defmodule Reencodarr.Dashboard.QueueItem do
  @moduledoc """
  Minimal queue item structure for dashboard display.
  Reduces memory usage by storing only the essential fields needed for UI.
  """

  @type t :: %__MODULE__{
          index: pos_integer(),
          path: String.t(),
          display_name: String.t(),
          estimated_percent: float() | nil
        }

  defstruct [:index, :path, :display_name, :estimated_percent]

  @doc """
  Creates a minimal queue item from a full video/file structure.
  Only extracts the fields needed for display to reduce memory usage.
  """
  def from_video(video, index) when is_map(video) do
    path = extract_path(video)

    %__MODULE__{
      index: index,
      path: path,
      display_name: Path.basename(path),
      estimated_percent: Map.get(video, :estimated_percent)
    }
  end

  # Extract path from various video/file structures
  defp extract_path(%{video: %{path: path}}) when is_binary(path), do: path
  defp extract_path(%{path: path}) when is_binary(path), do: path
  defp extract_path(_), do: "Unknown"
end
