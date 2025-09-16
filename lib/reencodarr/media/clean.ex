defmodule Reencodarr.Media.Clean do
  @moduledoc """
  Clean, focused Media context for Reencodarr.

  This module provides core CRUD operations for the Media domain without
  the clutter of statistics, debugging, or bulk operations. It maintains
  clear separation of concerns and provides a stable API for media operations.

  For specialized operations, see:
  - `Reencodarr.Media.Statistics` - Analytics and reporting
  - `Reencodarr.Media.BulkOperations` - Mass data operations
  - `Reencodarr.Media.VideoQueries` - Complex query logic
  """

  import Ecto.Query, warn: false

  alias Reencodarr.Core.Parsers

  alias Reencodarr.Analyzer.Broadway, as: AnalyzerBroadway

  alias Reencodarr.Media.{
    Library,
    Video,
    VideoFailure,
    VideoQueries,
    VideoUpsert,
    Vmaf
  }

  alias Reencodarr.Repo
  require Logger

  # === Video CRUD Operations ===

  @doc """
  Returns the list of videos ordered by most recently updated.
  """
  @spec list_videos() :: [Video.t()]
  def list_videos, do: Repo.all(from v in Video, order_by: [desc: v.updated_at])

  @doc """
  Gets a single video by ID, raising if not found.
  """
  @spec get_video!(integer()) :: Video.t()
  def get_video!(id), do: Repo.get!(Video, id)

  @doc """
  Gets a single video by ID, returning nil if not found.
  """
  @spec get_video(integer()) :: Video.t() | nil
  def get_video(id), do: Repo.get(Video, id)

  @doc """
  Gets a video by its file path.
  """
  @spec get_video_by_path(String.t()) :: Video.t() | nil
  def get_video_by_path(path), do: Repo.one(from v in Video, where: v.path == ^path)

  @doc """
  Checks if a video exists at the given path.
  """
  @spec video_exists?(String.t()) :: boolean()
  def video_exists?(path), do: Repo.exists?(from v in Video, where: v.path == ^path)

  @doc """
  Finds videos matching a path wildcard pattern.
  """
  @spec find_videos_by_path_wildcard(String.t()) :: [Video.t()]
  def find_videos_by_path_wildcard(pattern),
    do: Repo.all(from v in Video, where: like(v.path, ^pattern))

  @doc """
  Creates a video with the given attributes.
  """
  @spec create_video(map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def create_video(attrs \\ %{}) do
    %Video{} |> Video.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Creates or updates a video using upsert logic.

  Delegates to VideoUpsert for complex upsert handling.
  """
  @spec upsert_video(map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def upsert_video(attrs), do: VideoUpsert.upsert(attrs)

  @doc """
  Updates a video with the given attributes.
  """
  @spec update_video(Video.t(), map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def update_video(%Video{} = video, attrs) do
    video |> Video.changeset(attrs) |> Repo.update()
  end

  @doc """
  Deletes the given video.
  """
  @spec delete_video(Video.t()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def delete_video(%Video{} = video), do: Repo.delete(video)

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking video changes.
  """
  @spec change_video(Video.t(), map()) :: Ecto.Changeset.t()
  def change_video(%Video{} = video, attrs \\ %{}) do
    Video.changeset(video, attrs)
  end

  # === Video Query Delegations ===

  @doc """
  Counts videos ready for CRF search.
  """
  @spec count_videos_for_crf_search() :: integer()
  def count_videos_for_crf_search do
    VideoQueries.count_videos_for_crf_search()
  end

  @doc """
  Counts videos needing analysis.
  """
  @spec count_videos_needing_analysis() :: integer()
  def count_videos_needing_analysis do
    VideoQueries.count_videos_needing_analysis()
  end

  @doc """
  Gets the next video(s) for encoding.
  """
  @spec get_next_for_encoding(integer()) :: Vmaf.t() | [Vmaf.t()] | nil
  def get_next_for_encoding(limit \\ 1) do
    case limit do
      1 -> VideoQueries.videos_ready_for_encoding(1) |> List.first()
      _ -> VideoQueries.videos_ready_for_encoding(limit)
    end
  end

  @doc """
  Counts videos in the encoding queue.
  """
  @spec encoding_queue_count() :: integer()
  def encoding_queue_count do
    VideoQueries.encoding_queue_count()
  end

  @doc """
  Lists videos awaiting CRF search (analyzed but no VMAFs).
  """
  @spec list_videos_awaiting_crf_search() :: [Video.t()]
  def list_videos_awaiting_crf_search do
    from(v in Video,
      left_join: vmafs in assoc(v, :vmafs),
      where: is_nil(vmafs.id) and v.state == :analyzed,
      select: v
    )
    |> Repo.all()
  end

  @doc """
  Checks if a video has any VMAF records.
  """
  @spec video_has_vmafs?(Video.t()) :: boolean()
  def video_has_vmafs?(%Video{id: id}), do: Repo.exists?(from v in Vmaf, where: v.video_id == ^id)

  # === Video Failure Operations ===

  @doc """
  Gets unresolved failures for a video.
  """
  @spec get_video_failures(integer()) :: [VideoFailure.t()]
  def get_video_failures(video_id), do: VideoFailure.get_unresolved_failures_for_video(video_id)

  @doc """
  Resolves all failures for a video (typically when re-processing succeeds).
  """
  @spec resolve_video_failures(integer()) :: :ok
  def resolve_video_failures(video_id) do
    video_id
    |> VideoFailure.get_unresolved_failures_for_video()
    |> Enum.each(&VideoFailure.resolve_failure/1)
  end

  @doc """
  Gets failure statistics for monitoring and investigation.
  """
  @spec get_failure_statistics(keyword()) :: map()
  def get_failure_statistics(opts \\ []), do: VideoFailure.get_failure_statistics(opts)

  @doc """
  Gets common failure patterns for investigation.
  """
  @spec get_common_failure_patterns(integer()) :: [map()]
  def get_common_failure_patterns(limit \\ 10),
    do: VideoFailure.get_common_failure_patterns(limit)

  @doc """
  Forces complete re-analysis of a video by resetting all analysis data and manually queuing it.

  This function:
  1. Deletes all VMAFs for the video
  2. Resets video analysis fields (bitrate, etc.)
  3. Manually adds the video to the analyzer queue
  4. Returns the video path for verification

  ## Parameters
    - `video_id`: integer video ID

  ## Returns
    - `{:ok, video_path}` on success
    - `{:error, reason}` if video not found

  ## Examples
      iex> force_reanalyze_video(9008028)
      {:ok, "/path/to/video.mkv"}
  """
  @spec force_reanalyze_video(integer()) :: {:ok, String.t()} | {:error, String.t()}
  def force_reanalyze_video(video_id) when is_integer(video_id) do
    case get_video(video_id) do
      nil ->
        {:error, "Video #{video_id} not found"}

      video ->
        Repo.transaction(fn ->
          # 1. Delete all VMAFs
          delete_vmafs_for_video(video_id)

          # 2. Reset analysis fields to force re-analysis
          update_video(video, %{
            bitrate: nil,
            video_codecs: nil,
            audio_codecs: nil,
            max_audio_channels: nil,
            atmos: nil,
            hdr: nil,
            width: nil,
            height: nil,
            frame_rate: nil,
            duration: nil
          })

          # 3. Manually trigger analysis using Broadway dispatch
          AnalyzerBroadway.dispatch_available()

          video.path
        end)
        |> case do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # === Library CRUD Operations ===

  @doc """
  Returns the list of libraries.
  """
  @spec list_libraries() :: [Library.t()]
  def list_libraries, do: Repo.all(from(l in Library))

  @doc """
  Gets a single library by ID, raising if not found.
  """
  @spec get_library!(integer()) :: Library.t()
  def get_library!(id), do: Repo.get!(Library, id)

  @doc """
  Creates a library with the given attributes.
  """
  @spec create_library(map()) :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def create_library(attrs \\ %{}) do
    %Library{} |> Library.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Updates a library with the given attributes.
  """
  @spec update_library(Library.t(), map()) :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def update_library(%Library{} = l, attrs) do
    l |> Library.changeset(attrs) |> Repo.update()
  end

  @doc """
  Deletes the given library.
  """
  @spec delete_library(Library.t()) :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def delete_library(%Library{} = l), do: Repo.delete(l)

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking library changes.
  """
  @spec change_library(Library.t(), map()) :: Ecto.Changeset.t()
  def change_library(%Library{} = l, attrs \\ %{}) do
    Library.changeset(l, attrs)
  end

  # === VMAF CRUD Operations ===

  @doc """
  Returns the list of VMAFs.
  """
  @spec list_vmafs() :: [Vmaf.t()]
  def list_vmafs, do: Repo.all(Vmaf)

  @doc """
  Gets a single VMAF by ID with preloaded video.
  """
  @spec get_vmaf!(integer()) :: Vmaf.t()
  def get_vmaf!(id), do: Repo.get!(Vmaf, id) |> Repo.preload(:video)

  @doc """
  Creates a VMAF with the given attributes.
  """
  @spec create_vmaf(map()) :: {:ok, Vmaf.t()} | {:error, Ecto.Changeset.t()}
  def create_vmaf(attrs \\ %{}) do
    %Vmaf{} |> Vmaf.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Creates or updates a VMAF using upsert logic.
  """
  @spec upsert_vmaf(map()) :: {:ok, Vmaf.t()} | {:error, Ecto.Changeset.t()}
  def upsert_vmaf(attrs) do
    # Calculate savings if not provided but percent and video are available
    attrs_with_savings = maybe_calculate_savings(attrs)

    result =
      %Vmaf{}
      |> Vmaf.changeset(attrs_with_savings)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :video_id, :inserted_at]},
        conflict_target: [:crf, :video_id]
      )

    case result do
      {:ok, vmaf} ->
        Reencodarr.Telemetry.emit_vmaf_upserted(vmaf)

        # If this VMAF is chosen, update video state to crf_searched
        if vmaf.chosen do
          video = get_video!(vmaf.video_id)
          Reencodarr.Media.mark_as_crf_searched(video)
        end

      {:error, _error} ->
        :ok
    end

    result
  end

  @doc """
  Updates a VMAF with the given attributes.
  """
  @spec update_vmaf(Vmaf.t(), map()) :: {:ok, Vmaf.t()} | {:error, Ecto.Changeset.t()}
  def update_vmaf(%Vmaf{} = vmaf, attrs) do
    vmaf |> Vmaf.changeset(attrs) |> Repo.update()
  end

  @doc """
  Deletes the given VMAF.
  """
  @spec delete_vmaf(Vmaf.t()) :: {:ok, Vmaf.t()} | {:error, Ecto.Changeset.t()}
  def delete_vmaf(%Vmaf{} = vmaf), do: Repo.delete(vmaf)

  @doc """
  Deletes all VMAFs for a given video ID.

  ## Parameters
    - `video_id`: integer video ID

  ## Returns
    - `{count, nil}` where count is the number of deleted VMAFs

  ## Examples
      iex> delete_vmafs_for_video(123)
      {3, nil}
  """
  @spec delete_vmafs_for_video(integer()) :: {integer(), nil}
  def delete_vmafs_for_video(video_id) when is_integer(video_id) do
    from(v in Vmaf, where: v.video_id == ^video_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking VMAF changes.
  """
  @spec change_vmaf(Vmaf.t(), map()) :: Ecto.Changeset.t()
  def change_vmaf(%Vmaf{} = vmaf, attrs \\ %{}) do
    Vmaf.changeset(vmaf, attrs)
  end

  @doc """
  Checks if a chosen VMAF exists for the given video.
  """
  @spec chosen_vmaf_exists?(Video.t()) :: boolean()
  def chosen_vmaf_exists?(%{id: id}),
    do: Repo.exists?(from v in Vmaf, where: v.video_id == ^id and v.chosen == true)

  @doc """
  Lists all chosen VMAFs.
  """
  @spec list_chosen_vmafs() :: [Vmaf.t()]
  def list_chosen_vmafs do
    Repo.all(query_chosen_vmafs())
  end

  @doc """
  Gets the chosen VMAF for a specific video.
  """
  @spec get_chosen_vmaf_for_video(Video.t()) :: Vmaf.t() | nil
  def get_chosen_vmaf_for_video(%Video{id: video_id}) do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and v.video_id == ^video_id and vid.state == :crf_searched,
        preload: [:video],
        order_by: [asc: v.percent, asc: v.time]
    )
  end

  @doc """
  Marks a specific VMAF as chosen for a video and unmarks all others.
  """
  @spec mark_vmaf_as_chosen(integer(), String.t() | float()) ::
          {:ok, {integer(), nil}} | {:error, term()}
  def mark_vmaf_as_chosen(video_id, crf) do
    crf_float = parse_crf(crf)

    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id == ^video_id, update: [set: [chosen: false]])
      |> Repo.update_all([])

      from(v in Vmaf,
        where: v.video_id == ^video_id and v.crf == ^crf_float,
        update: [set: [chosen: true]]
      )
      |> Repo.update_all([])
    end)
  end

  # === Private Helper Functions ===

  # Calculate savings if not already provided and we have the necessary data
  defp maybe_calculate_savings(attrs) do
    case {Map.get(attrs, "savings"), Map.get(attrs, "percent"), Map.get(attrs, "video_id")} do
      {nil, percent, video_id}
      when (is_number(percent) or is_binary(percent)) and
             (is_integer(video_id) or is_binary(video_id)) ->
        case get_video(video_id) do
          %Video{size: size} when is_integer(size) and size > 0 ->
            savings = calculate_vmaf_savings(percent, size)
            Map.put(attrs, "savings", savings)

          _ ->
            attrs
        end

      _ ->
        attrs
    end
  end

  # Calculate estimated space savings in bytes based on percent and video size
  defp calculate_vmaf_savings(percent, video_size) when is_binary(percent) do
    case Parsers.parse_float_exact(percent) do
      {:ok, percent_float} -> calculate_vmaf_savings(percent_float, video_size)
      {:error, _} -> nil
    end
  end

  defp calculate_vmaf_savings(percent, video_size)
       when is_number(percent) and is_number(video_size) and
              percent > 0 and percent <= 100 do
    # Savings = (100 - percent) / 100 * original_size
    round((100 - percent) / 100 * video_size)
  end

  defp calculate_vmaf_savings(_, _), do: nil

  # Consolidated shared logic for chosen VMAF queries
  defp query_chosen_vmafs do
    from v in Vmaf,
      join: vid in assoc(v, :video),
      where: v.chosen == true and vid.state == :crf_searched,
      preload: [:video],
      order_by: [asc: v.percent, asc: v.time]
  end

  defp parse_crf(crf) do
    case Parsers.parse_float_exact(crf) do
      {:ok, float} -> float
      {:error, _} -> 0.0
    end
  end
end
