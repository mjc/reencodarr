defmodule Reencodarr.CrfSearcher do
  alias Reencodarr.{AbAv1, Media, Repo}
  require Logger

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(video) do
    vmafs = AbAv1.crf_search(video)
    {count, nil} = Repo.delete_all(Media.Vmaf, where: [video_id: video.id])
    Logger.debug("Deleted #{count} vmafs for video #{video.id}")
    Enum.map(vmafs, fn vmaf ->
      Media.create_vmaf(Map.merge(vmaf, %{"video_id" => video.id}))
    end)
    :ok
  end
end
