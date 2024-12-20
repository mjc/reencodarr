defmodule Reencodarr.Media do
  @moduledoc """
  The Media context.
  """

  import Ecto.Query, warn: false
  alias Reencodarr.Repo
  alias Reencodarr.Media.{Video, Library, Vmaf}
  require Logger

  defmodule Stats do
    defstruct [
      :not_reencoded,
      :reencoded,
      :total_videos,
      :avg_vmaf_percentage,
      :total_vmafs,
      :chosen_vmafs_count,
      :lowest_vmaf,
      :lowest_vmaf_by_time,
      :most_recent_video_update,
      :most_recent_inserted_video,
      :queue_length,
      :encode_queue_length
    ]
  end

  # Video-related functions
  @doc """
  Returns the list of videos.

  ## Examples

      iex> list_videos()
      [%Video{}, ...]

  """
  @spec list_videos() :: [Video.t()]
  def list_videos do
    Repo.all(from v in Video, order_by: [desc: v.updated_at])
  end

  @doc """
  Gets a single video.

  Raises `Ecto.NoResultsError` if the Video does not exist.

  ## Examples

      iex> get_video!(123)
      %Video{}

      iex> get_video!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_video!(integer()) :: Video.t()
  def get_video!(id), do: Repo.get!(Video, id)

  @doc """
  Gets a video by its path.

  ## Examples

      iex> get_video_by_path("/path/to/video.mp4")
      %Video{}

      iex> get_video_by_path("/path/to/nonexistent.mp4")
      nil

  """
  @spec get_video_by_path(String.t()) :: Video.t() | nil
  def get_video_by_path(path) do
    Repo.one(from v in Video, where: v.path == ^path)
  end

  @spec video_exists?(String.t()) :: boolean()
  def video_exists?(path) do
    Repo.exists?(from v in Video, where: v.path == ^path)
  end

  @doc """
  Finds videos by their path using wildcards.

  ## Examples

      iex> find_videos_by_path_wildcard("/path/to/%")
      [%Video{}, ...]

  """
  @spec find_videos_by_path_wildcard(String.t()) :: [Video.t()]
  def find_videos_by_path_wildcard(path_pattern) do
    Repo.all(from v in Video, where: like(v.path, ^path_pattern))
  end

  @doc """
  Finds videos without VMAFs.

  ## Examples

      iex> find_videos_without_vmafs(5)
      [%Video{}, ...]

  """
  @spec find_videos_without_vmafs(integer()) :: [Video.t()]
  def find_videos_without_vmafs(limit \\ 10) do
    Repo.all(
      from v in Video,
        left_join: m in Vmaf,
        on: m.video_id == v.id,
        where: is_nil(m.id) and v.reencoded == false and v.failed == false,
        order_by: [desc: v.size, asc: v.updated_at],
        limit: ^limit,
        select: v
    )
  end

  @doc """
  Creates a video.

  ## Examples

      iex> create_video(%{field: value})
      {:ok, %Video{}}

      iex> create_video(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_video(map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def create_video(attrs \\ %{}) do
    %Video{}
    |> Video.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Upserts a video.

  ## Examples

      iex> upsert_video(%{field: value})
      {:ok, %Video{}}

      iex> upsert_video(%{field: bad_value})
      {:error, %Ecto.Changeset.t()}
  """
  @spec upsert_video(map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def upsert_video(attrs) do
    attrs
    |> ensure_library_id()
    |> Video.changeset()
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :path
    )
  end

  @spec ensure_library_id(map()) :: map()
  defp ensure_library_id(%{library_id: nil} = attrs) do
    %{attrs | library_id: find_library_id(attrs[:path])}
  end

  defp ensure_library_id(attrs), do: attrs

  @spec find_library_id(String.t()) :: integer()
  defp find_library_id(path) do
    from(l in Library, where: like(^path, fragment("concat(?, '%')", l.path)), select: l.id)
    |> Repo.one()
  end

  @doc """
  Updates a video.

  ## Examples

      iex> update_video(video, %{field: new_value})
      {:ok, %Video{}}

      iex> update_video(video, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_video(Video.t(), map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def update_video(%Video{} = video, attrs) do
    video
    |> Video.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a video.

  ## Examples

      iex> delete_video(video)
      {:ok, %Video{}}

      iex> delete_video(video)
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_video(Video.t()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def delete_video(%Video{} = video), do: Repo.delete(video)

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking video changes.

  ## Examples

      iex> change_video(video)
      %Ecto.Changeset{data: %Video{}}

  """
  @spec change_video(Video.t(), map()) :: Ecto.Changeset.t()
  def change_video(%Video{} = video, attrs \\ %{}) do
    Video.changeset(video, attrs)
  end

  @doc """
  Marks a video as re-encoded.

  ## Examples

      iex> mark_as_reencoded(video)
      {:ok, %Video{}}

      iex> mark_as_reencoded(video)
      {:error, %Ecto.Changeset{}}

  """
  @spec mark_as_reencoded(Video.t()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def mark_as_reencoded(%Video{} = video) do
    video
    |> Video.changeset(%{reencoded: true, failed: false})
    |> Repo.update()
  end

  @doc """
  Marks a video as failed.

  ## Examples

      iex> mark_as_failed(video)
      {:ok, %Video{}}

      iex> mark_as_failed(video)
      {:error, %Ecto.Changeset{}}

  """
  @spec mark_as_failed(Video.t()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def mark_as_failed(%Video{} = video) do
    video
    |> Video.changeset(%{failed: true})
    |> Repo.update()
  end

  @doc """
  Returns the most recent updated_at timestamp for videos.

  ## Examples

      iex> most_recent_video_update()
      ~N[2023-10-05 14:30:00]

  """
  @spec most_recent_video_update() :: NaiveDateTime.t() | nil
  def most_recent_video_update do
    from(v in Video, select: max(v.updated_at))
    |> Repo.one()
  end

  @doc """
  Returns the most recent inserted_at timestamp for videos.

  ## Examples

      iex> get_most_recent_inserted_at()
      ~N[2023-10-05 14:30:00]

  """
  @spec get_most_recent_inserted_at() :: NaiveDateTime.t() | nil
  def get_most_recent_inserted_at do
    from(v in Video, select: max(v.inserted_at))
    |> Repo.one()
  end

  @spec video_has_vmafs?(Video.t()) :: boolean()
  def video_has_vmafs?(%Video{id: video_id}) do
    Repo.exists?(from v in Vmaf, where: v.video_id == ^video_id)
  end

  @doc """
  Deletes all videos where the path does not exist and their associated VMAFs.

  ## Examples

      iex> delete_videos_with_nonexistent_paths()
      {:ok, count}

  """
  @spec delete_videos_with_nonexistent_paths() :: {:ok, integer()} | {:error, term()}
  def delete_videos_with_nonexistent_paths do
    non_existent_videos =
      Repo.all(from v in Video, select: %{id: v.id, path: v.path})
      |> Enum.map(fn video ->
        Task.async(fn -> {video.id, File.exists?(video.path)} end)
      end)
      |> Enum.map(&Task.await/1)
      |> Enum.filter(fn {_id, exists} -> not exists end)
      |> Enum.map(&elem(&1, 0))

    Repo.transaction(fn ->
      # Delete associated VMAFs
      from(v in Vmaf, where: v.video_id in ^non_existent_videos)
      |> Repo.delete_all()

      # Delete videos
      from(v in Video, where: v.id in ^non_existent_videos)
      |> Repo.delete_all()
    end)
  end

  # Library-related functions
  @doc """
  Returns the list of libraries.

  ## Examples

      iex> list_libraries()
      [%Library{}, ...]

  """
  @spec list_libraries() :: [Library.t()]
  def list_libraries do
    Repo.all(Library)
  end

  @doc """
  Gets a single library.

  Raises `Ecto.NoResultsError` if the Library does not exist.

  ## Examples

      iex> get_library!(123)
      %Library{}

      iex> get_library!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_library!(integer()) :: Library.t()
  def get_library!(id), do: Repo.get!(Library, id)

  @doc """
  Creates a library.

  ## Examples

      iex> create_library(%{field: value})
      {:ok, %Library{}}

      iex> create_library(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_library(map()) :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def create_library(attrs \\ %{}) do
    %Library{}
    |> Library.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a library.

  ## Examples

      iex> update_library(library, %{field: new_value})
      {:ok, %Library{}}

      iex> update_library(library, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_library(Library.t(), map()) :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def update_library(%Library{} = library, attrs) do
    library
    |> Library.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a library.

  ## Examples

      iex> delete_library(library)
      {:ok, %Library{}}

      iex> delete_library(library)
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_library(Library.t()) :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def delete_library(%Library{} = library), do: Repo.delete(library)

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking library changes.

  ## Examples

      iex> change_library(library)
      %Ecto.Changeset{data: %Library{}}

  """
  @spec change_library(Library.t(), map()) :: Ecto.Changeset.t()
  def change_library(%Library{} = library, attrs \\ %{}) do
    Library.changeset(library, attrs)
  end

  # Vmaf-related functions
  @doc """
  Returns the list of vmafs.

  ## Examples

      iex> list_vmafs()
      [%Vmaf{}, ...]

  """
  def list_vmafs do
    Repo.all(Vmaf)
  end

  @doc """
  Gets a single vmaf.

  Raises `Ecto.NoResultsError` if the Vmaf does not exist.

  ## Examples

      iex> get_vmaf!(123)
      %Vmaf{}

      iex> get_vmaf!(456)
      ** (Ecto.NoResultsError)

  """
  def get_vmaf!(id) do
    Repo.get!(Vmaf, id)
    |> Repo.preload(:video)
  end

  @doc """
  Creates a vmaf.

  ## Examples

      iex> create_vmaf(%{field: value})
      {:ok, %Vmaf{}}

      iex> create_vmaf(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_vmaf(attrs \\ %{}) do
    %Vmaf{}
    |> Vmaf.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Upserts a vmaf.

  ## Examples

      iex> upsert_vmaf(%{field: value})
      {:ok, %Vmaf{}}

      iex> upsert_vmaf(%{field: bad_value})
      {:error, %Ecto.Changeset.t()}
  """
  @spec upsert_vmaf(map()) :: {:ok, Vmaf.t()} | {:error, Ecto.Changeset.t()}
  def upsert_vmaf(attrs) do
    %Vmaf{}
    |> Vmaf.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :video_id, :inserted_at]},
      conflict_target: [:crf, :video_id]
    )
  end

  @doc """
  Updates a vmaf.

  ## Examples

      iex> update_vmaf(vmaf, %{field: new_value})
      {:ok, %Vmaf{}}

      iex> update_vmaf(vmaf, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_vmaf(%Vmaf{} = vmaf, attrs) do
    vmaf
    |> Vmaf.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a vmaf.

  ## Examples

      iex> delete_vmaf(vmaf)
      {:ok, %Vmaf{}}

      iex> delete_vmaf(vmaf)
      {:error, %Ecto.Changeset{}}

  """
  def delete_vmaf(%Vmaf{} = vmaf) do
    Repo.delete(vmaf)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking vmaf changes.

  ## Examples

      iex> change_vmaf(vmaf)
      %Ecto.Changeset{data: %Vmaf{}}

  """
  def change_vmaf(%Vmaf{} = vmaf, attrs \\ %{}) do
    Vmaf.changeset(vmaf, attrs)
  end

  @spec chosen_vmaf_exists?(Video.t()) :: boolean()
  def chosen_vmaf_exists?(%{id: video_id}) do
    Repo.exists?(from v in Vmaf, where: v.video_id == ^video_id and v.chosen == true)
  end

  @doc """
  Returns the list of chosen vmafs sorted by smallest percent and time.

  ## Examples

      iex> list_chosen_vmafs()
      [%Vmaf{}, ...]

  """
  @spec list_chosen_vmafs() :: [Vmaf.t()]
  def list_chosen_vmafs do
    Repo.all(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.reencoded == false and vid.failed == false,
        order_by: [asc: v.percent, asc: v.time],
        preload: [:video]
    )
  end

  @doc """
  Gets the chosen Vmaf for a given video.

  ## Examples

      iex> get_chosen_vmaf_for_video(video)
      %Vmaf{}

      iex> get_chosen_vmaf_for_video(video)
      nil

  """
  @spec get_chosen_vmaf_for_video(Video.t()) :: Vmaf.t() | nil
  def get_chosen_vmaf_for_video(%Video{id: video_id}) do
    Repo.one(
      from v in Vmaf, where: v.video_id == ^video_id and v.chosen == true, preload: [:video]
    )
  end

  @doc """
  Finds the next not-reencoded video by chosen VMAF.

  ## Examples

      iex> find_next_video()
      %Video{}

      iex> find_next_video()
      nil

  """
  @spec find_next_video() :: Video.t() | nil
  def find_next_video do
    import Ecto.Query, warn: false
    alias Reencodarr.Media.{Video, Vmaf}

    query =
      from v in Video,
        join: m in Vmaf,
        on: m.video_id == v.id,
        where: v.reencoded == false and v.failed == false and m.chosen == true,
        order_by: [asc: m.percent, asc: m.time],
        limit: 1,
        select: v

    Repo.one(query)
  end

  @doc """
  Returns the count of videos grouped by reencoded status and additional stats.

  ## Examples

      iex> fetch_stats()
      %Media.Stats{
        not_reencoded: 5,
        reencoded: 10,
        total_videos: 15,
        avg_vmaf_percentage: 85.5,
        total_vmafs: 20,
        chosen_vmafs_count: 10,
        lowest_vmaf: %Vmaf{},
        lowest_vmaf_by_time: %Vmaf{},
        most_recent_video_update: ~N[2023-10-05 14:30:00],
        most_recent_inserted_video: ~N[2023-10-05 14:30:00],
        queue_length: %{encodes: 3, crf_searches: 5}
      }

  """
  @spec fetch_stats() :: %Stats{}
  def fetch_stats do
    counts = Repo.all(counts_query()) |> Enum.into(%{})
    total_videos = Repo.one(total_videos_query())
    avg_vmaf_percentage = Repo.one(avg_vmaf_percentage_query())
    total_vmafs = Repo.one(total_vmafs_query())
    chosen_vmafs_count = Repo.one(chosen_vmafs_count_query())
    encodes_count = Repo.one(encodes_count_query())
    queued_crf_searches_count = Repo.one(queued_crf_searches_count_query())
    lowest_vmaf = get_lowest_chosen_vmaf() || %Vmaf{}
    lowest_vmaf_by_time = get_lowest_chosen_vmaf_by_time() || %Vmaf{}
    most_recent_video_update = most_recent_video_update()
    most_recent_inserted_video = get_most_recent_inserted_at()

    %Stats{
      avg_vmaf_percentage: avg_vmaf_percentage,
      chosen_vmafs_count: chosen_vmafs_count,
      lowest_vmaf_by_time: lowest_vmaf_by_time,
      lowest_vmaf: lowest_vmaf,
      not_reencoded: Map.get(counts, false, 0),
      reencoded: Map.get(counts, true, 0),
      total_videos: total_videos,
      total_vmafs: total_vmafs,
      most_recent_video_update: most_recent_video_update,
      most_recent_inserted_video: most_recent_inserted_video,
      queue_length: %{encodes: encodes_count, crf_searches: queued_crf_searches_count}
    }
  end

  defp counts_query do
    from(v in Video,
      where: v.failed == false,
      group_by: v.reencoded,
      select: {v.reencoded, count(v.id)}
    )
  end

  defp total_videos_query do
    from(v in Video,
      where: v.failed == false,
      select: count(v.id)
    )
  end

  defp avg_vmaf_percentage_query do
    from(v in Vmaf,
      join: vid in assoc(v, :video),
      where: v.chosen == true and vid.failed == false,
      select: fragment("ROUND(CAST(AVG(?) AS numeric), 2)", v.percent)
    )
  end

  defp total_vmafs_query do
    from(v in Vmaf,
      join: vid in assoc(v, :video),
      where: vid.failed == false,
      select: count(v.id)
    )
  end

  defp chosen_vmafs_count_query do
    from(v in Vmaf,
      join: vid in assoc(v, :video),
      where: v.chosen == true and vid.failed == false,
      select: count(v.id)
    )
  end

  defp encodes_count_query do
    from v in Video,
      join: m in Vmaf,
      on: m.video_id == v.id,
      where: v.reencoded == false and v.failed == false and m.chosen == true,
      select: count(v.id)
  end

  defp queued_crf_searches_count_query do
    from v in Video,
      left_join: vmafs in assoc(v, :vmafs),
      where: is_nil(vmafs.id) and not v.reencoded and v.failed == false,
      select: count(v.id)
  end

  @doc """
  Returns the lowest chosen VMAF excluding reencoded videos.

  ## Examples

      iex> get_lowest_chosen_vmaf()
      %Vmaf{}

  """
  @spec get_lowest_chosen_vmaf() :: Vmaf.t() | nil
  def get_lowest_chosen_vmaf do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.reencoded == false and vid.failed == false,
        order_by: [asc: v.percent],
        limit: 1,
        preload: [:video]
    )
  end

  @doc """
  Returns the lowest chosen VMAF by time.

  ## Examples

      iex> get_lowest_chosen_vmaf_by_time()
      %Vmaf{}

  """
  @spec get_lowest_chosen_vmaf_by_time() :: Vmaf.t() | nil
  def get_lowest_chosen_vmaf_by_time do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and vid.reencoded == false and vid.failed == false,
        order_by: [asc: v.time],
        limit: 1,
        preload: [:video]
    )
  end

  @doc """
  Marks a VMAF as chosen.

  ## Examples

      iex> mark_vmaf_as_chosen(123, "32")
      {:ok, %Vmaf{}}

      iex> mark_vmaf_as_chosen(999, "32")
      {:error, %Ecto.Changeset{}}

  """
  @spec mark_vmaf_as_chosen(integer(), String.t()) ::
          {:ok, Vmaf.t()} | {:error, Ecto.Changeset.t()}
  def mark_vmaf_as_chosen(video_id, crf) do
    crf_float =
      if String.contains?(crf, ".") do
        String.to_float(crf)
      else
        String.to_float(crf <> ".0")
      end

    Repo.transaction(fn ->
      # Unset previously chosen VMAFs
      from(v in Vmaf,
        where: v.video_id == ^video_id,
        update: [set: [chosen: false]]
      )
      |> Repo.update_all([])

      # Set the chosen VMAF
      from(v in Vmaf,
        where: v.video_id == ^video_id and v.crf == ^crf_float,
        update: [set: [chosen: true]]
      )
      |> Repo.update_all([])
    end)
  end

  def queued_crf_searches_query do
    from v in Video,
      left_join: vmafs in assoc(v, :vmafs),
      where: is_nil(vmafs.id) and not v.reencoded and v.failed == false,
      select: v
  end
end
