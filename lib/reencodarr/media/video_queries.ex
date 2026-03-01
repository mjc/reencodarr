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
  Excludes videos already in crf_searching state to avoid showing currently processing videos.

  ## Options
  - `:timeout` - Query timeout in milliseconds (default: 15000)
  """
  @spec videos_for_crf_search(integer(), keyword()) :: [Video.t()]
  def videos_for_crf_search(limit \\ 10, opts \\ []) do
    # Simplified query - just check state, let Rules filter codecs at encode time
    Repo.all(
      from(v in Video,
        where: v.state == :analyzed,
        order_by: [desc: v.bitrate, desc: v.size, asc: v.updated_at],
        limit: ^limit,
        select: v
      ),
      opts
    )
  end

  @doc """
  Counts the total number of videos ready for CRF search.
  Excludes videos already in crf_searching state.
  """
  @spec count_videos_for_crf_search(keyword()) :: integer()
  def count_videos_for_crf_search(opts \\ []) do
    # Simplified query - just check state, codec filtering happens at encode time
    Repo.one(
      from(v in Video,
        where: v.state == :analyzed,
        select: count()
      ),
      opts
    )
  end

  @doc """
  Gets videos needing analysis (state: needs_analysis).

  These videos lack required metadata and need MediaInfo analysis.

  ## Options
  - `:timeout` - Query timeout in milliseconds (default: 15000)
  """
  @spec videos_needing_analysis(integer(), keyword()) :: [Video.t()]
  def videos_needing_analysis(limit \\ 10, opts \\ []) do
    Repo.all(
      from(v in Video,
        where: v.state == :needs_analysis,
        order_by: [
          desc: v.size,
          desc: v.inserted_at,
          desc: v.updated_at
        ],
        limit: ^limit,
        select: v
      ),
      opts
    )
  end

  @doc """
  Counts the total number of videos needing analysis.
  """
  @spec count_videos_needing_analysis(keyword()) :: integer()
  def count_videos_needing_analysis(opts \\ []) do
    Repo.one(
      from(v in Video,
        where: v.state == :needs_analysis,
        select: count()
      ),
      opts
    )
  end

  @doc """
  Gets videos ready for encoding with complex alternation logic between services and libraries.
  Uses 9:1 Sonarr:Radarr ratio and alternates between libraries within each service.

  ## Options
  - `:timeout` - Query timeout in milliseconds (default: 15000)
  """
  @spec videos_ready_for_encoding(integer(), keyword()) :: [Vmaf.t()]
  def videos_ready_for_encoding(limit, opts \\ []) do
    Repo.all(
      from(vid in Video,
        join: v in Vmaf,
        on: vid.chosen_vmaf_id == v.id,
        where: vid.state == :crf_searched,
        order_by: [fragment("? DESC NULLS LAST", v.savings), desc: vid.updated_at],
        limit: ^limit,
        select: %{v | video: vid}
      ),
      opts
    )
  end

  @doc """
  Counts total videos ready for encoding.
  """
  @spec encoding_queue_count(keyword()) :: integer()
  def encoding_queue_count(opts \\ []) do
    Repo.one(
      from(vid in Video,
        where: vid.state == :crf_searched and not is_nil(vid.chosen_vmaf_id),
        select: count(vid.id)
      ),
      opts
    )
  end
end
