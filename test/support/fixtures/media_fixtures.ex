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

  @doc """
  Generate a unique library path.
  """
  def unique_library_path, do: "some path#{System.unique_integer([:positive])}"

  @doc """
  Generate a library.
  """
  def library_fixture(attrs \\ %{}) do
    {:ok, library} =
      attrs
      |> Enum.into(%{
        monitor: true,
        path: unique_library_path()
      })
      |> Reencodarr.Media.create_library()

    library
  end

  @doc """
  Generate a vmaf.
  """
  def vmaf_fixture(attrs \\ %{}) do
    {:ok, vmaf} =
      attrs
      |> Enum.into(%{
        crf: 120.5,
        score: 120.5,
        # Changed to an empty list for array of strings
        params: []
      })
      |> Reencodarr.Media.create_vmaf()

    vmaf
  end
end
