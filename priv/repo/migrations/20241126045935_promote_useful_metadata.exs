defmodule Reencodarr.Repo.Migrations.PromoteUsefulMetadata do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :duration, :float
      add :width, :integer
      add :height, :integer
      add :frame_rate, :float
      add :video_count, :integer
      add :audio_count, :integer
      add :text_count, :integer
      add :hdr, :string
      add :video_codecs, {:array, :string}
      add :audio_codecs, {:array, :string}
      add :text_codecs, {:array, :string}
    end
  end
end
