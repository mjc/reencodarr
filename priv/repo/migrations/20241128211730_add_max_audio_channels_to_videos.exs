defmodule Reencodarr.Repo.Migrations.AddMaxAudioChannelsToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :max_audio_channels, :integer, default: 0
    end
  end
end
