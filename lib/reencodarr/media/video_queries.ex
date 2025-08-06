defmodule Reencodarr.Media.VideoQueries do
  @moduledoc """
  Centralizes complex video query logic to reduce complexity in the Media module.

  This module handles the intricate logic for alternating between services and libraries
  when selecting videos for encoding, CRF search, and analysis.
  """

  import Ecto.Query
  alias Reencodarr.{Media.Video, Media.Vmaf, Repo}

  @doc """
  Gets videos ready for CRF search (no existing VMAFs, not reencoded/failed, not AV1/Opus).
  """
  @spec videos_for_crf_search(integer()) :: [Video.t()]
  def videos_for_crf_search(limit \\ 10) do
    Repo.all(
      from v in Video,
        left_join: m in Vmaf,
        on: m.video_id == v.id,
        where:
          is_nil(m.id) and v.reencoded == false and v.failed == false and
            not fragment(
              "EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))",
              v.audio_codecs,
              "%opus%"
            ) and
            not fragment(
              "EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))",
              v.video_codecs,
              "%av1%"
            ),
        order_by: [
          desc: v.bitrate,
          desc: v.size,
          asc: v.updated_at
        ],
        limit: ^limit,
        select: v
    )
  end

  @doc """
  Gets videos needing analysis (no bitrate calculated, not failed).
  """
  @spec videos_needing_analysis(integer()) :: [map()]
  def videos_needing_analysis(limit \\ 10) do
    Repo.all(
      from v in Video,
        where: is_nil(v.bitrate) and v.failed == false,
        order_by: [
          desc: v.size,
          desc: v.inserted_at,
          desc: v.updated_at
        ],
        limit: ^limit,
        select: %{
          path: v.path,
          service_id: v.service_id,
          service_type: v.service_type,
          force_reanalyze: false
        }
    )
  end

  @doc """
  Gets videos ready for encoding with complex alternation logic between services and libraries.
  Uses 9:1 Sonarr:Radarr ratio and alternates between libraries within each service.
  """
  @spec videos_ready_for_encoding(integer()) :: [Vmaf.t()]
  def videos_ready_for_encoding(limit) do
    sonarr_videos = videos_by_service_type("sonarr", sonarr_limit(limit))
    radarr_videos = videos_by_service_type("radarr", radarr_limit(limit))

    alternate_by_service_type(sonarr_videos, radarr_videos, limit)
  end

  @doc """
  Counts total videos ready for encoding.
  """
  @spec encoding_queue_count() :: integer()
  def encoding_queue_count do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.reencoded == false and vid.failed == false,
        select: count(v.id)
    )
  end

  # Private functions for complex query logic

  # Calculate limits with 9:1 ratio (90% Sonarr, 10% Radarr)
  defp sonarr_limit(total_limit), do: max(1, round(total_limit * 9 / 10) + 2)
  defp radarr_limit(total_limit), do: max(1, round(total_limit / 10) + 2)

  defp videos_by_service_type(service_type, limit) do
    library_ids = active_library_ids_for_service(service_type)

    case library_ids do
      [] -> []
      _ -> fetch_videos_alternating_libraries(library_ids, service_type, limit)
    end
  end

  defp active_library_ids_for_service(service_type) do
    Repo.all(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where:
          v.chosen == true and vid.reencoded == false and vid.failed == false and
            vid.service_type == ^service_type and not is_nil(vid.library_id),
        distinct: vid.library_id,
        select: vid.library_id
    )
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_videos_alternating_libraries(library_ids, service_type, limit) do
    videos_per_library = max(1, div(limit, length(library_ids)) + 1)

    videos_by_library =
      library_ids
      |> Task.async_stream(
        fn library_id ->
          videos =
            Repo.all(
              from v in Vmaf,
                join: vid in assoc(v, :video),
                where:
                  v.chosen == true and vid.reencoded == false and vid.failed == false and
                    vid.library_id == ^library_id and vid.service_type == ^service_type,
                order_by: [
                  fragment("? DESC NULLS LAST", v.savings),
                  asc: v.percent,
                  asc: v.time
                ],
                limit: ^videos_per_library,
                preload: [:video]
            )

          {library_id, videos}
        end,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.into(%{})

    alternate_libraries(videos_by_library, library_ids, limit)
  end

  # Alternate between Sonarr and Radarr with 9:1 ratio
  defp alternate_by_service_type(sonarr_videos, radarr_videos, limit) do
    0..(limit - 1)
    |> Enum.reduce({[], 0, 0}, fn index, {acc, s_idx, r_idx} ->
      # Every 10th position gets a Radarr video (9:1 ratio)
      if rem(index, 10) == 9 do
        add_video_from_list(radarr_videos, r_idx, acc, s_idx, :radarr)
      else
        add_video_from_list(sonarr_videos, s_idx, acc, r_idx, :sonarr)
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp add_video_from_list(videos, current_idx, acc, other_idx, :radarr) do
    case Enum.at(videos, current_idx) do
      nil -> {acc, other_idx, current_idx}
      video -> {[video | acc], other_idx, current_idx + 1}
    end
  end

  defp add_video_from_list(videos, current_idx, acc, other_idx, :sonarr) do
    case Enum.at(videos, current_idx) do
      nil -> {acc, current_idx, other_idx}
      video -> {[video | acc], current_idx + 1, other_idx}
    end
  end

  # Alternate between libraries using efficient indexed access
  defp alternate_libraries(videos_by_library, library_ids, limit) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(limit)
    |> Stream.map(fn index ->
      library_index = rem(index, length(library_ids))
      library_id = Enum.at(library_ids, library_index)
      video_position = div(index, length(library_ids))

      videos_by_library[library_id] |> Enum.at(video_position)
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end
end
