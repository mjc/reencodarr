defmodule Reencodarr.MediaFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Reencodarr.Media` context.
  """

  @doc """
  Generate a video.
  """
  def video_fixture(attrs \\ %{}) do
    {:ok, video} =
      attrs
      |> Enum.into(%{
        bitrate: 42,
        path: "some path",
        size: 42
      })
      |> Reencodarr.Media.create_video()

    video
  end
end
