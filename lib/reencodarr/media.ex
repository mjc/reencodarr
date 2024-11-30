defmodule Reencodarr.Media do
  @moduledoc """
  The Media context.
  """

  import Ecto.Query, warn: false
  alias Reencodarr.Repo
  alias Reencodarr.Media.{Video, Library, Vmaf}
  require Logger

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
      {:error, %Ecto.Changeset{}}
  """
  @spec upsert_video(map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def upsert_video(attrs) do
    attrs
    |> ensure_library_id()
    |> Video.changeset()
    |> Repo.insert(on_conflict: {:replace_all_except, [:id]}, conflict_target: :path)
    |> broadcast_change()
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

  @spec broadcast_change({:ok, Video.t()} | {:error, Ecto.Changeset.t()}) ::
          {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  defp broadcast_change({:ok, video}) do
    ReencodarrWeb.Endpoint.broadcast("videos", "video:upsert", %{video: video})
    {:ok, video}
  end

  defp broadcast_change({:error, changeset}), do: {:error, changeset}

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

  alias Reencodarr.Media.Vmaf

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
      {:error, %Ecto.Changeset{}}
  """
  @spec upsert_vmaf(map()) :: {:ok, Vmaf.t()} | {:error, Ecto.Changeset.t()}
  def upsert_vmaf(attrs) do
    %Vmaf{}
    |> Vmaf.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :video_id]},
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
        where: v.chosen == true,
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
        where: v.reencoded == false and m.chosen == true,
        order_by: [asc: m.percent, asc: m.time],
        limit: 1,
        select: v

    Repo.one(query)
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
    |> Video.changeset(%{reencoded: true})
    |> Repo.update()
  end

  @spec process_vmafs([Vmaf.t()]) :: :ok | :error
  def process_vmafs(vmafs) do
    Enum.reduce_while(vmafs, :error, fn vmaf, acc ->
      case upsert_vmaf(vmaf) do
        {:ok, %{chosen: true} = vmaf} ->
          Logger.info(
            "Chosen crf: #{vmaf.crf}, chosen score: #{vmaf.score}, chosen percent: #{vmaf.percent}, chosen size: #{vmaf.size}, chosen time: #{vmaf.time}"
          )

          {:halt, :ok}

        _ ->
          {:cont, acc}
      end
    end)
  end

  @doc """
  Returns the count of videos grouped by reencoded status and additional stats.

  ## Examples

      iex> fetch_stats()
      %{true => 10, false => 5, total_videos: 15, avg_vmaf_percentage: 85.5, total_vmafs: 20}

  """
  @spec fetch_stats() :: %{boolean() => integer(), total_videos: integer(), avg_vmaf_percentage: float(), total_vmafs: integer()}
  def fetch_stats do
    counts = from(v in Video, group_by: v.reencoded, select: {v.reencoded, count(v.id)})
             |> Repo.all()
             |> Enum.into(%{})
    total_videos = Repo.aggregate(Video, :count, :id)
    avg_vmaf_percentage = from(v in Vmaf, where: v.chosen == true, select: fragment("ROUND(CAST(AVG(?) AS numeric), 2)", v.percent))
                          |> Repo.one()
    total_vmafs = Repo.aggregate(Vmaf, :count, :id)
    Map.merge(counts, %{total_videos: total_videos, avg_vmaf_percentage: avg_vmaf_percentage, total_vmafs: total_vmafs})
  end

  @doc """
  Returns the lowest chosen VMAF percentage.

  ## Examples

      iex> lowest_chosen_vmaf_percentage()
      75.5

  """
  @spec lowest_chosen_vmaf_percentage() :: float() | nil
  def lowest_chosen_vmaf_percentage do
    from(v in Vmaf, where: v.chosen == true, select: fragment("MIN(?)", v.percent))
    |> Repo.one()
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
        where: v.chosen == true and vid.reencoded == false,
        order_by: [asc: v.percent],
        limit: 1
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
        where: v.chosen == true,
        order_by: [asc: v.time],
        limit: 1,
        preload: [:video]
    )
  end
end
