defmodule Reencodarr.MediaFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Reencodarr.Media` context.

  Fixtures support both simple creation and factory-style building:

      # Simple creation with defaults
      video = video_fixture()

      # Override specific attributes
      video = video_fixture(%{path: "/custom/path.mkv", bitrate: 5000})

      # Factory-style building
      video = build_video() |> with_high_bitrate() |> with_hdr() |> create()
  """

  alias Reencodarr.Media

  @doc """
  Generate a video with default or custom attributes.
  """
  def video_fixture(attrs \\ %{}) do
    # Always use unique path to prevent database conflicts, even if path is provided in attrs
    unique_path =
      case Map.get(attrs, :path) do
        nil ->
          unique_video_path()

        path when is_binary(path) ->
          # Make any provided path unique by appending a unique integer
          base = Path.rootname(path)
          ext = Path.extname(path)
          "#{base}_#{System.unique_integer([:positive])}#{ext}"

        path ->
          path
      end

    default_attrs = %{
      # 5 Mbps - more realistic default
      bitrate: 5_000_000,
      path: unique_path,
      # 2GB - realistic file size
      size: 2_000_000_000,
      reencoded: false,
      failed: false
    }

    {:ok, video} =
      default_attrs
      # Remove path from attrs since we handle it above
      |> Map.merge(Map.delete(attrs, :path))
      |> Media.create_video()

    video
  end

  @doc """
  Generate multiple videos with a common prefix.

      videos = videos_fixture(3, %{path_prefix: "/movies"})
  """
  def videos_fixture(count, base_attrs \\ %{}) do
    1..count
    |> Enum.map(fn i ->
      attrs =
        Map.put(base_attrs, :path, "#{Map.get(base_attrs, :path_prefix, "/test")}/video_#{i}.mkv")

      video_fixture(attrs)
    end)
  end

  @doc """
  Generate a high-bitrate video (typically needs encoding).
  """
  def high_bitrate_video_fixture(attrs \\ %{}) do
    attrs
    # 15 Mbps
    |> Map.put_new(:bitrate, 15_000_000)
    # 5GB
    |> Map.put_new(:size, 5_000_000_000)
    |> video_fixture()
  end

  @doc """
  Generate an HDR video.
  """
  def hdr_video_fixture(attrs \\ %{}) do
    attrs
    # 25 Mbps for HDR
    |> Map.put_new(:bitrate, 25_000_000)
    |> video_fixture()
  end

  @doc """
  Generate a video that has already been reencoded.
  """
  def reencoded_video_fixture(attrs \\ %{}) do
    attrs
    |> Map.put(:reencoded, true)
    # Lower after encoding
    |> Map.put_new(:bitrate, 3_000_000)
    |> video_fixture()
  end

  @doc """
  Generate a failed video (analysis or encoding failed).
  """
  def failed_video_fixture(attrs \\ %{}) do
    attrs
    |> Map.put(:failed, true)
    |> video_fixture()
  end

  # Factory-style builders

  @doc """
  Start building a video with factory pattern.

      video = build_video() |> with_high_bitrate() |> create()
  """
  def build_video(attrs \\ %{}) do
    default_attrs = %{
      bitrate: 5_000_000,
      path: unique_video_path(),
      size: 2_000_000_000,
      reencoded: false,
      failed: false
    }

    Map.merge(default_attrs, attrs)
  end

  def with_high_bitrate(attrs, bitrate \\ 15_000_000) do
    Map.put(attrs, :bitrate, bitrate)
  end

  def with_path(attrs, path) do
    Map.put(attrs, :path, path)
  end

  def as_reencoded(attrs) do
    Map.put(attrs, :reencoded, true)
  end

  def as_failed(attrs) do
    Map.put(attrs, :failed, true)
  end

  def create(attrs) do
    {:ok, video} = Media.create_video(attrs)
    video
  end

  @doc """
  Generate a unique video file path.
  """
  def unique_video_path do
    "/test/videos/video_#{System.unique_integer([:positive])}.mkv"
  end

  @doc """
  Generate a unique library path.
  """
  def unique_library_path do
    "/test/libraries/library_#{System.unique_integer([:positive])}"
  end

  @doc """
  Generate a library with default or custom attributes.
  """
  def library_fixture(attrs \\ %{}) do
    default_attrs = %{
      monitor: true,
      path: unique_library_path()
    }

    {:ok, library} =
      default_attrs
      |> Map.merge(attrs)
      |> Media.create_library()

    library
  end

  @doc """
  Generate multiple libraries.
  """
  def libraries_fixture(count, base_attrs \\ %{}) do
    1..count
    |> Enum.map(fn _i ->
      library_fixture(base_attrs)
    end)
  end

  @doc """
  Generate a VMAF record with default or custom attributes.
  """
  def vmaf_fixture(attrs \\ %{}) do
    # Ensure we have a video to associate with
    video = Map.get_lazy(attrs, :video, fn -> video_fixture() end)

    default_attrs = %{
      video_id: video.id,
      crf: 28.0,
      score: 95.5,
      params: ["--preset", "medium"]
    }

    {:ok, vmaf} =
      default_attrs
      |> Map.merge(attrs)
      # Remove video from attrs before creating
      |> Map.drop([:video])
      |> Media.create_vmaf()

    # Add video back for convenience
    %{vmaf | video: video}
  end

  @doc """
  Generate multiple VMAF records for CRF search testing.
  """
  def vmaf_series_fixture(video, crf_range \\ [24, 26, 28, 30, 32]) do
    Enum.map(crf_range, fn crf ->
      # Simulate decreasing quality with higher CRF
      score = 100 - (crf - 20) * 2
      vmaf_fixture(%{video_id: video.id, crf: crf, score: score})
    end)
  end

  @doc """
  Generate VMAF records showing optimal encoding results.
  """
  def optimal_vmaf_fixture(video, target_score \\ 95.0) do
    vmaf_fixture(%{
      video_id: video.id,
      crf: 28.0,
      score: target_score
    })
  end
end
