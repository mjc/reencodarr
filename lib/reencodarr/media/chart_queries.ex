defmodule Reencodarr.Media.ChartQueries do
  @moduledoc "Database queries for dashboard chart data."

  import Ecto.Query
  alias Reencodarr.Media.{Video, Vmaf}
  alias Reencodarr.Repo

  @vmaf_bins [
    {"<80", 0, 80},
    {"80-85", 80, 85},
    {"85-90", 85, 90},
    {"90-92", 90, 92},
    {"92-94", 92, 94},
    {"94-96", 94, 96},
    {"96-98", 96, 98},
    {"98+", 98, 101}
  ]

  @resolution_categories [
    {"4K+", 3840},
    {"1440p", 2560},
    {"1080p", 1920},
    {"720p", 1280},
    {"<720p", 0}
  ]

  @codec_map %{
    # HEVC / H.265 variants
    "v_mpegh/iso/hevc" => "HEVC",
    "hevc" => "HEVC",
    "h265" => "HEVC",
    "h.265" => "HEVC",
    "x265" => "HEVC",
    "hev1" => "HEVC",
    "hvc1" => "HEVC",
    "dvhe" => "HEVC",
    # H.264 / AVC variants
    "v_mpeg4/iso/avc" => "H.264",
    "h264" => "H.264",
    "h.264" => "H.264",
    "x264" => "H.264",
    "avc" => "H.264",
    "avc1" => "H.264",
    "27" => "H.264",
    # AV1 variants
    "v_av1" => "AV1",
    "av1" => "AV1",
    "av01" => "AV1",
    # VP9
    "v_vp9" => "VP9",
    "vp9" => "VP9",
    "vp09" => "VP9",
    # MPEG-2
    "v_mpeg2" => "MPEG-2",
    "mpeg2" => "MPEG-2",
    # MPEG-4 ASP (DivX/XviD)
    "v_mpeg4/iso/asp" => "MPEG-4",
    "mpeg4" => "MPEG-4",
    "mp4v-20" => "MPEG-4",
    "xvid" => "MPEG-4",
    "divx" => "MPEG-4",
    "dx50" => "MPEG-4",
    # VC-1
    "vc1" => "VC-1",
    "vc-1" => "VC-1",
    "v_ms/vfw/fourcc / wvc1" => "VC-1"
  }

  @doc "Get VMAF score distribution as histogram bins for chosen VMAFs."
  def vmaf_score_distribution do
    scores =
      from(v in Vmaf,
        join: vid in Video,
        on: vid.chosen_vmaf_id == v.id,
        where: not is_nil(v.score),
        select: v.score
      )
      |> Repo.all()

    Enum.map(@vmaf_bins, fn {label, low, high} ->
      count = Enum.count(scores, fn s -> s >= low and s < high end)
      {label, count}
    end)
  end

  @doc "Get video count by resolution category."
  def resolution_distribution do
    videos =
      from(v in Video,
        where: not is_nil(v.width) and v.state != :failed,
        select: v.width
      )
      |> Repo.all()

    @resolution_categories
    |> Enum.map(fn {label, min_width} ->
      {label, min_width, next_threshold(min_width)}
    end)
    |> Enum.map(fn {label, min_w, max_w} ->
      count = Enum.count(videos, fn w -> w >= min_w and w < max_w end)
      {label, count}
    end)
    |> Enum.filter(fn {_, count} -> count > 0 end)
  end

  defp next_threshold(3840), do: 100_000
  defp next_threshold(2560), do: 3840
  defp next_threshold(1920), do: 2560
  defp next_threshold(1280), do: 1920
  defp next_threshold(0), do: 1280

  @doc "Get primary codec distribution across all videos."
  def codec_distribution do
    from(v in Video,
      where: not is_nil(v.video_codecs),
      select: v.video_codecs
    )
    |> Repo.all()
    |> Enum.map(fn
      [first | _] -> normalize_codec(first)
      _ -> "unknown"
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(8)
  end

  defp normalize_codec(codec) when is_binary(codec) do
    @codec_map[String.downcase(codec)] || String.upcase(codec)
  end

  defp normalize_codec(_), do: "unknown"
end
