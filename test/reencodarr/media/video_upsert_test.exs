defmodule Reencodarr.Media.VideoUpsertTest do
  use Reencodarr.DataCase
  import ExUnit.CaptureLog

  alias Reencodarr.Media.{Library, Video, VideoUpsert}
  alias Reencodarr.Repo

  setup do
    # Create a library for testing
    library =
      %Library{
        path: "/mnt/test",
        monitor: true
      }
      |> Repo.insert!()

    {:ok, library: library}
  end

  describe "upsert/1" do
    test "creates a new video with valid attributes", %{library: library} do
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id
      }

      assert {:ok, %Video{} = video} = VideoUpsert.upsert(attrs)
      assert video.path == "/mnt/test/show/episode.mkv"
      assert video.size == 1_000_000
      assert video.library_id == library.id
    end

    test "updates existing video when path matches", %{library: library} do
      # Create initial video
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id
      }

      {:ok, original_video} = VideoUpsert.upsert(attrs)

      # Update with new size
      updated_attrs = Map.merge(attrs, %{"size" => 2_000_000})
      assert {:ok, %Video{} = updated_video} = VideoUpsert.upsert(updated_attrs)

      assert updated_video.id == original_video.id
      assert updated_video.size == 2_000_000
      assert updated_video.path == original_video.path
    end

    test "handles stale update errors gracefully", %{library: library} do
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id,
        "dateAdded" => "2020-01-01T00:00:00Z"
      }

      # Create initial video with recent timestamp
      {:ok, video} = VideoUpsert.upsert(attrs)

      # Try to update with older dateAdded (should be skipped due to stale check)
      old_attrs = Map.merge(attrs, %{"dateAdded" => "2019-01-01T00:00:00Z", "size" => 3_000_000})

      # Should return the existing video without error
      assert {:ok, %Video{} = result_video} = VideoUpsert.upsert(old_attrs)
      assert result_video.id == video.id
      # Size should not be updated due to stale dateAdded
      assert result_video.size == video.size
    end

    test "finds library_id automatically based on path", %{library: library} do
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"]
        # Note: no library_id provided
      }

      assert {:ok, %Video{} = video} = VideoUpsert.upsert(attrs)
      assert video.library_id == library.id
    end

    test "adds default values for required fields" do
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"]
        # Missing max_audio_channels and atmos
      }

      assert {:ok, %Video{} = video} = VideoUpsert.upsert(attrs)
      # default value
      assert video.max_audio_channels == 6
      # default value
      assert video.atmos == false
    end

    test "returns error for invalid attributes" do
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv"
        # Missing required fields like size
      }

      capture_log(fn ->
        result = VideoUpsert.upsert(attrs)
        assert {:error, %Ecto.Changeset{}} = result
      end)
    end
  end

  describe "batch_upsert/1" do
    test "processes multiple videos in a single transaction", %{library: library} do
      video_attrs_list = [
        %{
          "path" => "/mnt/test/show/episode1.mkv",
          "size" => 1_000_000,
          "duration" => 3600.0,
          "bitrate" => 8_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        },
        %{
          "path" => "/mnt/test/show/episode2.mkv",
          "size" => 1_200_000,
          "duration" => 3800.0,
          "bitrate" => 9_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        }
      ]

      results = VideoUpsert.batch_upsert(video_attrs_list)

      assert length(results) == 2
      assert Enum.all?(results, fn result -> match?({:ok, %Video{}}, result) end)

      [result1, result2] = results
      {:ok, video1} = result1
      {:ok, video2} = result2

      assert video1.path == "/mnt/test/show/episode1.mkv"
      assert video2.path == "/mnt/test/show/episode2.mkv"
    end

    test "handles mix of successful and failed upserts", %{library: library} do
      video_attrs_list = [
        %{
          "path" => "/mnt/test/show/valid.mkv",
          "size" => 1_000_000,
          "duration" => 3600.0,
          "bitrate" => 8_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        },
        %{
          "path" => "/mnt/test/show/invalid.mkv"
          # Missing required fields
        }
      ]

      capture_log(fn ->
        results = VideoUpsert.batch_upsert(video_attrs_list)

        assert length(results) == 2
        [result1, result2] = results

        assert {:ok, %Video{}} = result1
        assert {:error, %Ecto.Changeset{}} = result2
      end)
    end

    test "handles stale update errors in batch processing", %{library: library} do
      # Create initial video
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id,
        "dateAdded" => "2023-01-01T00:00:00Z"
      }

      {:ok, _video} = VideoUpsert.upsert(attrs)

      # Try batch update with older dateAdded
      batch_attrs = [
        Map.merge(attrs, %{"dateAdded" => "2020-01-01T00:00:00Z", "size" => 2_000_000})
      ]

      results = VideoUpsert.batch_upsert(batch_attrs)
      assert length(results) == 1

      [result] = results
      # Should succeed and return existing video (not an error)
      assert {:ok, %Video{}} = result
    end

    test "returns empty list for empty input" do
      results = VideoUpsert.batch_upsert([])
      assert results == []
    end

    test "handles transaction failures gracefully" do
      # Test with data that has nil path (causes query failure)
      invalid_attrs_list = [
        %{
          # Empty path instead of nil
          "path" => "",
          # Invalid size
          "size" => "not_a_number"
        }
      ]

      capture_log(fn ->
        results = VideoUpsert.batch_upsert(invalid_attrs_list)
        assert length(results) == 1
        [result] = results
        assert {:error, _} = result
      end)
    end
  end

  describe "bitrate preservation logic" do
    test "preserves bitrate when file hasn't changed", %{library: library} do
      # Create initial video
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id
      }

      {:ok, original_video} = VideoUpsert.upsert(attrs)

      # Update with same file characteristics but different metadata
      updated_attrs =
        Map.merge(attrs, %{
          # Different bitrate
          "bitrate" => 10_000_000,
          "mediainfo" => "different metadata"
        })

      {:ok, updated_video} = VideoUpsert.upsert(updated_attrs)

      # Bitrate should be preserved since file characteristics are same
      assert updated_video.bitrate == original_video.bitrate
      assert updated_video.id == original_video.id
    end

    test "updates bitrate when file has changed", %{library: library} do
      # Create initial video
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id
      }

      {:ok, original_video} = VideoUpsert.upsert(attrs)

      # Update with different file characteristics
      updated_attrs =
        Map.merge(attrs, %{
          # Different size
          "size" => 2_000_000,
          # Different bitrate
          "bitrate" => 10_000_000
        })

      {:ok, updated_video} = VideoUpsert.upsert(updated_attrs)

      # Bitrate should be updated since file has changed
      assert updated_video.bitrate == 10_000_000
      assert updated_video.size == 2_000_000
      assert updated_video.id == original_video.id
    end
  end
end
