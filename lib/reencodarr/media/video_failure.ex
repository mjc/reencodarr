defmodule Reencodarr.Media.VideoFailure do
  use Ecto.Schema
  import Ecto.Changeset
  alias Reencodarr.Media.Video

  @moduledoc """
  Tracks detailed failure information for video processing pipeline.

  Captures granular failure data including stage, category, retry information,
  and system context to enable better debugging and monitoring.
  """

  @type t() :: %__MODULE__{}

  # Processing stages where failures can occur
  @failure_stages [
    # MediaInfo parsing, file access
    :analysis,
    # VMAF/CRF determination
    :crf_search,
    # ab-av1 encoding process
    :encoding,
    # File operations, sync
    :post_process
  ]

  # Broad failure categories for grouping and investigation
  @failure_categories [
    # Analysis stage categories
    # File not found, permission denied
    :file_access,
    # MediaInfo command failed or malformed output
    :mediainfo_parsing,
    # Schema validation failures
    :validation,

    # CRF search stage categories
    # VMAF scoring issues
    :vmaf_calculation,
    # CRF search algorithm failures
    :crf_optimization,
    # File size predictions exceed limits
    :size_limits,
    # --preset 6 retry scenarios
    :preset_retry,

    # Encoding stage categories
    # ab-av1 process crashes or non-zero exit
    :process_failure,
    # System resources (memory, disk, CPU)
    :resource_exhaustion,
    # Video/audio codec compatibility
    :codec_issues,
    # Process timeout
    :timeout,

    # Post-processing stage categories
    # Move, copy, rename failures
    :file_operations,
    # Sonarr/Radarr sync issues
    :sync_integration,
    # Temporary file cleanup issues
    :cleanup,

    # Cross-cutting categories
    # Invalid settings or parameters
    :configuration,
    # Missing dependencies, PATH issues
    :system_environment,
    # Unclassified failures
    :unknown
  ]

  schema "video_failures" do
    belongs_to :video, Video

    field :failure_stage, Ecto.Enum, values: @failure_stages
    field :failure_category, Ecto.Enum, values: @failure_categories
    field :failure_code, :string
    field :failure_message, :string
    field :system_context, :map
    field :retry_count, :integer, default: 0
    field :resolved, :boolean, default: false
    field :resolved_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(video_failure \\ %__MODULE__{}, attrs) do
    video_failure
    |> cast(attrs, [
      :video_id,
      :failure_stage,
      :failure_category,
      :failure_code,
      :failure_message,
      :system_context,
      :retry_count,
      :resolved,
      :resolved_at
    ])
    |> validate_required([:video_id, :failure_stage, :failure_category, :failure_message])
    |> validate_inclusion(:failure_stage, @failure_stages)
    |> validate_inclusion(:failure_category, @failure_categories)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:video_id)
  end

  @doc """
  Creates a failure record with contextual system information.

  ## Examples

      iex> record_failure(video, :encoding, :process_failure,
      ...>   code: "1", message: "ab-av1 failed", context: %{exit_code: 1})
      {:ok, %VideoFailure{}}
  """
  def record_failure(video, stage, category, opts \\ [])
      when is_atom(stage) and is_atom(category) do
    code = Keyword.get(opts, :code)
    message = Keyword.get(opts, :message, "Failure occurred")
    context = Keyword.get(opts, :context, %{})
    retry_count = Keyword.get(opts, :retry_count, 0)

    # Enhance context with system information
    enhanced_context =
      Map.merge(context, %{
        elixir_version: System.version(),
        os_type: format_os_type(:os.type()),
        timestamp: DateTime.utc_now(),
        node: to_string(Node.self())
      })

    attrs = %{
      video_id: video.id,
      failure_stage: stage,
      failure_category: category,
      failure_code: code,
      failure_message: message,
      system_context: enhanced_context,
      retry_count: retry_count
    }

    Reencodarr.Repo.insert(changeset(%__MODULE__{}, attrs))
  end

  @doc """
  Marks a failure as resolved.
  """
  def resolve_failure(%__MODULE__{} = failure) do
    failure
    |> changeset(%{resolved: true, resolved_at: DateTime.utc_now()})
    |> Reencodarr.Repo.update()
  end

  @doc """
  Gets all unresolved failures for a video.
  """
  def get_unresolved_failures_for_video(video_id) do
    import Ecto.Query

    from(f in __MODULE__,
      where: f.video_id == ^video_id and f.resolved == false,
      order_by: [desc: f.inserted_at]
    )
    |> Reencodarr.Repo.all()
  end

  @doc """
  Gets failure statistics grouped by stage and category.
  """
  def get_failure_statistics(opts \\ []) do
    import Ecto.Query

    days_back = Keyword.get(opts, :days_back, 7)
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back * 24 * 60 * 60, :second)

    query =
      from(f in __MODULE__,
        where: f.inserted_at >= ^cutoff_date,
        group_by: [f.failure_stage, f.failure_category],
        select: %{
          stage: f.failure_stage,
          category: f.failure_category,
          count: count(f.id),
          resolved_count: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", f.resolved))
        },
        order_by: [desc: count(f.id)]
      )

    Reencodarr.Repo.all(query)
  end

  @doc """
  Gets the most common failure patterns for investigation.
  """
  def get_common_failure_patterns(limit \\ 10) do
    import Ecto.Query

    query =
      from(f in __MODULE__,
        where: f.resolved == false,
        group_by: [f.failure_stage, f.failure_category, f.failure_code],
        select: %{
          stage: f.failure_stage,
          category: f.failure_category,
          code: f.failure_code,
          count: count(f.id),
          latest_occurrence: max(f.inserted_at),
          sample_message: fragment("string_agg(distinct ?, ' | ')", f.failure_message)
        },
        order_by: [desc: count(f.id)],
        limit: ^limit
      )

    Reencodarr.Repo.all(query)
  end

  @doc """
  Returns available failure stages.
  """
  def failure_stages, do: @failure_stages

  @doc """
  Returns available failure categories.
  """
  def failure_categories, do: @failure_categories

  # Private helper to format OS type tuple for JSON serialization
  defp format_os_type({family, name}), do: "#{family}/#{name}"
  defp format_os_type(other), do: to_string(other)
end
