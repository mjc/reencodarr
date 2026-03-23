defmodule Reencodarr.Media.BadFileIssue do
  use Ecto.Schema
  import Ecto.Changeset

  alias Reencodarr.Media.Video

  @origins [:audit, :manual]
  @issue_kinds [:audio, :manual]

  @classifications_by_issue_kind %{
    audio: [:confirmed_bad_audio_layout, :likely_bad_pre_commit_multichannel_opus],
    manual: [:manual_bad]
  }

  @statuses [
    :open,
    :queued,
    :processing,
    :waiting_for_replacement,
    :replaced_clean,
    :failed,
    :dismissed
  ]

  @type t() :: %__MODULE__{}

  schema "bad_file_issues" do
    belongs_to :video, Video

    field :origin, Ecto.Enum, values: @origins
    field :issue_kind, Ecto.Enum, values: @issue_kinds

    field :classification, Ecto.Enum,
      values: Enum.flat_map(@classifications_by_issue_kind, fn {_k, vals} -> vals end)

    field :status, Ecto.Enum, values: @statuses, default: :open
    field :manual_reason, :string
    field :manual_note, :string

    field :source_audio_codec, :string
    field :source_channels, :integer
    field :source_layout, :string
    field :output_audio_codec, :string
    field :output_channels, :integer
    field :output_layout, :string

    field :details, :map, default: %{}
    field :arr_command_ids, :map, default: %{}
    field :last_attempted_at, :utc_datetime
    field :resolved_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(issue \\ %__MODULE__{}, attrs) do
    issue
    |> cast(attrs, [
      :video_id,
      :origin,
      :issue_kind,
      :classification,
      :status,
      :manual_reason,
      :manual_note,
      :source_audio_codec,
      :source_channels,
      :source_layout,
      :output_audio_codec,
      :output_channels,
      :output_layout,
      :details,
      :arr_command_ids,
      :last_attempted_at,
      :resolved_at
    ])
    |> validate_required([:video_id, :origin, :issue_kind, :classification, :status])
    |> validate_inclusion(:origin, @origins)
    |> validate_inclusion(:issue_kind, @issue_kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_classification_for_issue_kind()
    |> validate_manual_fields()
    |> foreign_key_constraint(:video_id)
  end

  def origin_values, do: @origins
  def issue_kind_values, do: @issue_kinds
  def status_values, do: @statuses
  def classifications_by_issue_kind, do: @classifications_by_issue_kind

  defp validate_classification_for_issue_kind(changeset) do
    issue_kind = get_field(changeset, :issue_kind)
    classification = get_field(changeset, :classification)

    valid_classifications = Map.get(@classifications_by_issue_kind, issue_kind, [])

    if classification in valid_classifications do
      changeset
    else
      add_error(changeset, :classification, "is invalid")
    end
  end

  defp validate_manual_fields(changeset) do
    if get_field(changeset, :issue_kind) == :manual do
      validate_required(changeset, [:manual_reason])
    else
      changeset
    end
  end
end
