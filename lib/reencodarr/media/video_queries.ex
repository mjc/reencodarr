defmodule Reencodarr.Media.VideoQueries do
  @moduledoc """
  Centralizes complex video query logic to reduce complexity in the Media module.

  This module handles the intricate logic for alternating between services and libraries
  when selecting videos for encoding, CRF search, and analysis.
  """

  import Ecto.Query
  alias Reencodarr.{Media.Video, Media.Vmaf, Repo}

  @doc """
  Gets videos ready for CRF search (state: analyzed).
  """
  @spec videos_for_crf_search(integer()) :: [Video.t()]
  def videos_for_crf_search(limit \\ 10) do
    # SQLite3 implementation for video codec filtering
    Repo.all(
      from v in Video,
        where:
          v.state == :analyzed and
            not fragment(
              "EXISTS (SELECT 1 FROM json_each(?) WHERE json_each.value = ?)",
              v.video_codecs,
              "av1"
            ) and
            not fragment(
              "EXISTS (SELECT 1 FROM json_each(?) WHERE json_each.value = ?)",
              v.audio_codecs,
              "opus"
            ),
        order_by: [desc: v.bitrate, desc: v.size, asc: v.updated_at],
        limit: ^limit,
        select: v
    )
  end

  @doc """
  Counts the total number of videos ready for CRF search.
  """
  @spec count_videos_for_crf_search() :: integer()
  def count_videos_for_crf_search do
    # SQLite3 implementation for video codec filtering
    Repo.one(
      from v in Video,
        where:
          v.state == :analyzed and
            not fragment(
              "EXISTS (SELECT 1 FROM json_each(?) WHERE json_each.value = ?)",
              v.video_codecs,
              "av1"
            ) and
            not fragment(
              "EXISTS (SELECT 1 FROM json_each(?) WHERE json_each.value = ?)",
              v.audio_codecs,
              "opus"
            ),
        select: count()
    )
  end

  @doc """
  Gets videos needing analysis (state: needs_analysis).

  These videos lack required metadata and need MediaInfo analysis.
  """
  @spec videos_needing_analysis(integer()) :: [map()]
  def videos_needing_analysis(limit \\ 10) do
    Repo.all(
      from v in Video,
        where: v.state == :needs_analysis,
        order_by: [
          desc: v.size,
          desc: v.inserted_at,
          desc: v.updated_at
        ],
        limit: ^limit,
        select: %{
          id: v.id,
          path: v.path,
          service_id: v.service_id,
          service_type: v.service_type
        }
    )
  end

  @doc """
  Counts the total number of videos needing analysis.
  """
  @spec count_videos_needing_analysis() :: integer()
  def count_videos_needing_analysis do
    Repo.one(
      from v in Video,
        where: v.state == :needs_analysis,
        select: count()
    )
  end

  @doc """
  Gets videos ready for encoding with complex alternation logic between services and libraries.
  Uses 9:1 Sonarr:Radarr ratio and alternates between libraries within each service.
  """
  @spec videos_ready_for_encoding(integer()) :: [Vmaf.t()]
  def videos_ready_for_encoding(limit) do
    Repo.all(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.state == :crf_searched,
        order_by: [fragment("? DESC NULLS LAST", v.savings), desc: vid.updated_at],
        limit: ^limit,
        preload: [:video],
        select: v
    )
  end

  @doc """
  Counts total videos ready for encoding.
  """
  @spec encoding_queue_count() :: integer()
  def encoding_queue_count do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.state == :crf_searched,
        select: count(v.id)
    )
  end
end
