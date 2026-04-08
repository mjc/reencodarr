defmodule Reencodarr.Media.DashboardQueueCache do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "dashboard_queue_cache" do
    field :queue_type, Ecto.Enum, values: [:analyzer, :crf_searcher, :encoder]
    field :video_id, :integer
    field :path, :string
    field :priority, :integer
    field :bitrate, :integer
    field :size, :integer
    field :savings, :integer
    field :inserted_at, :utc_datetime
    field :updated_at, :utc_datetime
  end
end
