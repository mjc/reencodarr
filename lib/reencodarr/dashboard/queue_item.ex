defmodule Reencodarr.Dashboard.QueueItem do
  @moduledoc """
  Minimal queue item structure for dashboard display.
  Reduces memory usage by storing only the essential fields needed for UI.
  """

  @type t :: %__MODULE__{
          index: pos_integer(),
          path: String.t(),
          display_name: String.t(),
          estimated_percent: float() | nil,
          # CRF search specific
          bitrate: integer() | nil,
          size: integer() | nil,
          # Encoding specific
          estimated_savings_bytes: integer() | nil
        }

  defstruct [
    :index,
    :path,
    :display_name,
    :estimated_percent,
    :bitrate,
    :size,
    :estimated_savings_bytes
  ]

  @doc """
  Creates a minimal queue item from a full video/file structure.
  Only extracts the fields needed for display to reduce memory usage.
  """
  def from_video(video, index) when is_map(video) do
    path = extract_path(video)

    # Extract different data based on the type of queue item
    cond do
      # VMAF struct (encoding queue) - has video field and percent
      Map.has_key?(video, :video) and Map.has_key?(video, :percent) ->
        video_data = Map.get(video, :video, %{})
        video_size = Map.get(video_data, :size, 0)

        # Always use the savings field from the database - don't fallback to calculation
        estimated_savings_bytes = Map.get(video, :savings)

        %__MODULE__{
          index: index,
          path: path,
          display_name: clean_display_name(Path.basename(path)),
          estimated_percent: Map.get(video, :estimated_percent),
          estimated_savings_bytes: estimated_savings_bytes,
          size: video_size
        }

      # Video struct (CRF search or analyzer queue)
      true ->
        bitrate = Map.get(video, :bitrate)
        size = Map.get(video, :size)

        %__MODULE__{
          index: index,
          path: path,
          display_name: clean_display_name(Path.basename(path)),
          estimated_percent: Map.get(video, :estimated_percent),
          bitrate: bitrate,
          size: size
        }
    end
  end

  # Extract path from various video/file structures
  defp extract_path(%{video: %{path: path}}) when is_binary(path), do: path
  defp extract_path(%{path: path}) when is_binary(path), do: path
  defp extract_path(_), do: "Unknown"

  # Clean up display name to make it more readable
  defp clean_display_name(filename) do
    filename
    # Remove file extensions
    |> String.replace(~r/\.(mkv|mp4|avi|mov|wmv|flv|webm)$/i, "")
    # Remove quality indicators
    |> String.replace(~r/\b(WEBDL|WEB-DL|BluRay|BDRip|DVDRip|HDTV|WEBRip|BRRip)\b/i, "")
    # Remove codec info
    |> String.replace(~r/\b(x264|x265|H\.264|H\.265|HEVC|AVC|XviD)\b/i, "")
    # Remove resolution info
    |> String.replace(~r/\b(1080p|720p|2160p|4K|UHD|480p)\b/i, "")
    # Remove audio codec info
    |> String.replace(~r/\b(AAC|AC3|DTS|TrueHD|Atmos|MP3|FLAC)\b/i, "")
    # Remove years in parentheses like (2023)
    |> String.replace(~r/\s*\(\d{4}\)/, "")
    # Remove standalone years
    |> String.replace(~r/\b\d{4}\b/, "")
    # Remove release group tags like "R04DK1"
    |> String.replace(~r/\bR\d+DK\d+\b/i, "")
    # Remove release flags
    |> String.replace(~r/\b(REPACK|PROPER|INTERNAL|LIMITED)\b/i, "")
    # Keep season/episode but clean surrounding
    |> String.replace(~r/\b(S\d{2}E\d{2})\b/i, "\\1")
    # Remove trailing dashes
    |> String.replace(~r/\s*-\s*$/, "")
    # Normalize internal dashes
    |> String.replace(~r/\s*-\s*/, " - ")
    # Collapse multiple spaces
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.trim("-")
    |> String.trim()
    |> shorten_common_titles()
    # Limit to 35 characters for better display
    |> truncate_title(35)
  end

  # Shorten common long title patterns
  defp shorten_common_titles(title) do
    title
    |> String.replace("THE HANDMAID'S TALE", "Handmaid's Tale")
    |> String.replace("THE PHOENICIAN SCHEME", "Phoenician Scheme")
    |> String.replace("GONE IN SIXTY SECONDS", "Gone in 60 Seconds")
    |> String.replace("LOVE AFTER WORLD DOMINATION", "Love After World Dom")
    |> String.replace("DOCTOR WHO", "Dr Who")
    |> String.replace("FLIGHT RISK", "Flight Risk")
    |> String.replace("TWISTED METAL", "Twisted Metal")
    |> String.replace("TSUGUMOMO", "Tsugumomo")
    # Remove "THE " at the beginning
    |> String.replace(~r/\bTHE\s+/, "")
    |> to_title_case()
  end

  # Convert to title case for better readability
  defp to_title_case(title) do
    title
    |> String.downcase()
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
    # Keep episode format uppercase
    |> String.replace(~r/\b(S\d{2}E\d{2})\b/i, fn match -> String.upcase(match) end)
  end

  # Truncate title intelligently - try to keep full words
  defp truncate_title(title, max_length) when byte_size(title) <= max_length, do: title

  defp truncate_title(title, max_length) do
    if byte_size(title) <= max_length do
      title
    else
      # Try to truncate at word boundary
      truncated = String.slice(title, 0, max_length - 3)

      # Find the last space to avoid cutting words
      words = String.split(truncated, " ")

      case length(words) do
        1 ->
          truncated <> "..."

        _ ->
          # Remove the last (potentially partial) word and add ellipsis
          words
          |> Enum.drop(-1)
          |> Enum.join(" ")
          |> Kernel.<>("...")
      end
    end
  end
end
