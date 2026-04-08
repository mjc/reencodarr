defmodule Reencodarr.Media.ChartQueries do
  @moduledoc "Database queries for dashboard chart data."

  import Ecto.Query
  alias Reencodarr.Media.Video
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
    case Repo.query(
           """
           SELECT
             CASE
               WHEN v.score < 80 THEN '<80'
               WHEN v.score < 85 THEN '80-85'
               WHEN v.score < 90 THEN '85-90'
               WHEN v.score < 92 THEN '90-92'
               WHEN v.score < 94 THEN '92-94'
               WHEN v.score < 96 THEN '94-96'
               WHEN v.score < 98 THEN '96-98'
               ELSE '98+'
             END AS bucket,
             COUNT(*)
           FROM videos AS vid
           INNER JOIN vmafs AS v ON vid.chosen_vmaf_id = v.id
           WHERE v.score IS NOT NULL
           GROUP BY bucket
           """,
           []
         ) do
      {:ok, %{rows: rows}} ->
        counts =
          Map.new(rows, fn [label, count] ->
            {label, count}
          end)

        Enum.map(@vmaf_bins, fn {label, _low, _high} ->
          {label, Map.get(counts, label, 0)}
        end)

      {:error, error} ->
        raise error
    end
  end

  @doc "Get video count by resolution category."
  def resolution_distribution do
    case Repo.query(
           """
           SELECT
             CASE
               WHEN width >= 3840 THEN '4K+'
               WHEN width >= 2560 THEN '1440p'
               WHEN width >= 1920 THEN '1080p'
               WHEN width >= 1280 THEN '720p'
               ELSE '<720p'
             END AS bucket,
             COUNT(*)
           FROM videos
           WHERE width IS NOT NULL AND state != 'failed'
           GROUP BY bucket
           """,
           []
         ) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [label, count] -> {label, count} end)
        |> Enum.sort_by(fn {label, _} -> resolution_order(label) end)

      {:error, error} ->
        raise error
    end
  end

  defp resolution_order("4K+"), do: 0
  defp resolution_order("1440p"), do: 1
  defp resolution_order("1080p"), do: 2
  defp resolution_order("720p"), do: 3
  defp resolution_order("<720p"), do: 4

  @doc "Get primary codec distribution across all videos (top 8)."
  def codec_distribution do
    from(v in Video,
      where: not is_nil(v.video_codecs) and v.video_codecs != [],
      select: v.video_codecs
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn codecs, acc ->
      codec =
        case codecs do
          [first | _] -> normalize_codec(first)
          _ -> "unknown"
        end

      Map.update(acc, codec, 1, &(&1 + 1))
    end)
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(8)
  end

  defp normalize_codec(codec) when is_binary(codec) do
    @codec_map[String.downcase(codec)] || String.upcase(codec)
  end

  defp normalize_codec(_), do: "unknown"
end
