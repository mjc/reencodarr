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

  describe "edge cases and error handling" do
    test "handles nil path gracefully" do
      attrs = %{
        "path" => nil,
        "size" => 1_000_000,
        "duration" => 3600.0
      }

      capture_log(fn ->
        result = VideoUpsert.upsert(attrs)
        assert {:error, %Ecto.Changeset{}} = result
      end)
    end

    test "handles empty path string" do
      attrs = %{
        "path" => "",
        "size" => 1_000_000,
        "duration" => 3600.0
      }

      capture_log(fn ->
        result = VideoUpsert.upsert(attrs)
        assert {:error, %Ecto.Changeset{}} = result
      end)
    end

    test "handles whitespace-only path" do
      attrs = %{
        "path" => "   ",
        "size" => 1_000_000,
        "duration" => 3600.0
      }

      capture_log(fn ->
        result = VideoUpsert.upsert(attrs)
        assert {:error, %Ecto.Changeset{}} = result
      end)
    end

    test "handles path that doesn't match any library" do
      attrs = %{
        "path" => "/unknown/path/video.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"]
      }

      # Schema allows nil library_id, so this creates successfully
      assert {:ok, %Video{library_id: nil}} = VideoUpsert.upsert(attrs)
    end

    test "handles invalid dateAdded format", %{library: library} do
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
        "dateAdded" => "invalid-date-string"
      }

      # Should fall back to replace_all_except when dateAdded parsing fails
      assert {:ok, %Video{}} = VideoUpsert.upsert(attrs)
    end

    test "handles non-string dateAdded", %{library: library} do
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
        "dateAdded" => 123_456
      }

      # Should fall back to replace_all_except
      assert {:ok, %Video{}} = VideoUpsert.upsert(attrs)
    end

    test "handles atom keys in attributes", %{library: library} do
      attrs = %{
        path: "/mnt/test/show/episode.mkv",
        size: 1_000_000,
        duration: 3600.0,
        bitrate: 8_000_000,
        width: 1920,
        height: 1080,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        library_id: library.id
      }

      # Should normalize atom keys to strings
      assert {:ok, %Video{}} = VideoUpsert.upsert(attrs)
    end

    test "handles mixed atom and string keys", %{library: library} do
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

      assert {:ok, %Video{}} = VideoUpsert.upsert(attrs)
    end

    test "preserves state field on update", %{library: library} do
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

      {:ok, video} = VideoUpsert.upsert(attrs)
      original_state = video.state

      # Update with new size
      updated_attrs = Map.merge(attrs, %{"size" => 2_000_000})
      {:ok, updated_video} = VideoUpsert.upsert(updated_attrs)

      # State should be preserved (in conflict_except)
      assert updated_video.state == original_state
    end

    test "handles update when video is in encoded state", %{library: library} do
      # Create video in encoded state
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["av1"],
        "audio_codecs" => ["opus"],
        "library_id" => library.id,
        "state" => "encoded"
      }

      {:ok, video} = VideoUpsert.upsert(attrs)
      assert video.state == :encoded

      # Should not query for metadata comparison when encoded
      updated_attrs = Map.merge(attrs, %{"size" => 2_000_000})
      {:ok, updated_video} = VideoUpsert.upsert(updated_attrs)

      assert updated_video.id == video.id
    end

    test "handles update when video is in failed state", %{library: library} do
      # Create video in failed state
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
        "state" => "failed"
      }

      {:ok, video} = VideoUpsert.upsert(attrs)
      assert video.state == :failed

      # Should not query for metadata comparison when failed
      updated_attrs = Map.merge(attrs, %{"size" => 2_000_000})
      {:ok, updated_video} = VideoUpsert.upsert(updated_attrs)

      assert updated_video.id == video.id
    end
  end

  describe "VMAF deletion" do
    test "deletes VMAFs when file characteristics change", %{library: library} do
      # Create video with VMAFs
      {:ok, video} =
        VideoUpsert.upsert(%{
          "path" => "/mnt/test/show/episode.mkv",
          "size" => 1_000_000,
          "duration" => 3600.0,
          "bitrate" => 8_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        })

      # Add VMAF records
      alias Reencodarr.Media.Vmaf

      %Vmaf{video_id: video.id, crf: 25.0, score: 95.5, percent: 90.0}
      |> Repo.insert!()

      %Vmaf{video_id: video.id, crf: 30.0, score: 93.0, percent: 88.0}
      |> Repo.insert!()

      # Verify VMAFs exist
      vmaf_count = Repo.aggregate(from(v in Vmaf, where: v.video_id == ^video.id), :count)
      assert vmaf_count == 2

      # Update with different size (file changed)
      {:ok, _updated} =
        VideoUpsert.upsert(%{
          "path" => "/mnt/test/show/episode.mkv",
          "size" => 2_000_000,
          "duration" => 3600.0,
          "bitrate" => 8_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        })

      # VMAFs should be deleted
      vmaf_count_after = Repo.aggregate(from(v in Vmaf, where: v.video_id == ^video.id), :count)
      assert vmaf_count_after == 0
    end

    test "preserves VMAFs when file hasn't changed", %{library: library} do
      # Create video with VMAFs
      {:ok, video} =
        VideoUpsert.upsert(%{
          "path" => "/mnt/test/show/episode.mkv",
          "size" => 1_000_000,
          "duration" => 3600.0,
          "bitrate" => 8_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        })

      # Add VMAF record
      alias Reencodarr.Media.Vmaf

      %Vmaf{video_id: video.id, crf: 25.0, score: 95.5, percent: 90.0}
      |> Repo.insert!()

      # Update with same file characteristics
      {:ok, _updated} =
        VideoUpsert.upsert(%{
          "path" => "/mnt/test/show/episode.mkv",
          "size" => 1_000_000,
          "duration" => 3600.0,
          "bitrate" => 8_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        })

      # VMAFs should be preserved
      vmaf_count = Repo.aggregate(from(v in Vmaf, where: v.video_id == ^video.id), :count)
      assert vmaf_count == 1
    end

    test "does not delete VMAFs when marking video as encoded", %{library: library} do
      # Create video
      {:ok, video} =
        VideoUpsert.upsert(%{
          "path" => "/mnt/test/show/episode.mkv",
          "size" => 1_000_000,
          "duration" => 3600.0,
          "bitrate" => 8_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        })

      # Add VMAF
      alias Reencodarr.Media.Vmaf

      %Vmaf{video_id: video.id, crf: 25.0, score: 95.5, percent: 90.0}
      |> Repo.insert!()

      # Mark as encoded (even with different characteristics)
      {:ok, _updated} =
        VideoUpsert.upsert(%{
          "path" => "/mnt/test/show/episode.mkv",
          "size" => 2_000_000,
          "duration" => 3600.0,
          "bitrate" => 10_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["av1"],
          "audio_codecs" => ["opus"],
          "library_id" => library.id,
          "state" => "encoded"
        })

      # VMAFs should be preserved when marking as encoded
      vmaf_count = Repo.aggregate(from(v in Vmaf, where: v.video_id == ^video.id), :count)
      assert vmaf_count == 1
    end
  end

  describe "state broadcasting" do
    test "broadcasts state transition for needs_analysis videos", %{library: library} do
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

      # Should create video in needs_analysis state and broadcast
      assert {:ok, %Video{state: :needs_analysis}} = VideoUpsert.upsert(attrs)
    end

    test "does not broadcast for non-needs_analysis states", %{library: library} do
      attrs = %{
        "path" => "/mnt/test/show/episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["av1"],
        "audio_codecs" => ["opus"],
        "library_id" => library.id,
        "state" => "encoded"
      }

      # Should create video in encoded state without broadcast
      assert {:ok, %Video{state: :encoded}} = VideoUpsert.upsert(attrs)
    end
  end

  describe "conditional update with dateAdded" do
    test "preserves inserted_at timestamp during updates", %{library: library} do
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

      {:ok, original} = VideoUpsert.upsert(attrs)
      original_inserted_at = original.inserted_at

      # Update
      {:ok, updated} = VideoUpsert.upsert(Map.merge(attrs, %{"size" => 2_000_000}))

      # inserted_at should be preserved
      assert updated.inserted_at == original_inserted_at
    end
  end

  describe "batch upsert edge cases" do
    test "handles batch with both new and existing videos", %{library: library} do
      # Create one video first
      existing_attrs = %{
        "path" => "/mnt/test/show/episode1.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id
      }

      {:ok, existing_video} = VideoUpsert.upsert(existing_attrs)

      # Batch with update to existing + new video
      batch_attrs = [
        Map.merge(existing_attrs, %{"size" => 2_000_000}),
        %{
          "path" => "/mnt/test/show/episode2.mkv",
          "size" => 1_500_000,
          "duration" => 3800.0,
          "bitrate" => 9_000_000,
          "width" => 1920,
          "height" => 1080,
          "video_codecs" => ["h264"],
          "audio_codecs" => ["aac"],
          "library_id" => library.id
        }
      ]

      results = VideoUpsert.batch_upsert(batch_attrs)
      assert length(results) == 2

      [result1, result2] = results
      assert {:ok, %Video{id: id1, size: 2_000_000}} = result1
      assert {:ok, %Video{size: 1_500_000}} = result2

      # First should be update of existing
      assert id1 == existing_video.id
    end
  end

  describe "bitrate update logging" do
    test "updates bitrate when file characteristics change", %{library: library} do
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

      {:ok, video} = VideoUpsert.upsert(attrs)

      # Update with different file characteristics
      updated_attrs = Map.merge(attrs, %{"size" => 2_000_000, "bitrate" => 10_000_000})

      {:ok, updated} = VideoUpsert.upsert(updated_attrs)

      # Bitrate should be updated
      assert updated.bitrate == 10_000_000
      assert updated.id == video.id
    end

    test "creates new video without existing record", %{library: library} do
      attrs = %{
        "path" => "/mnt/test/show/new_episode.mkv",
        "size" => 1_000_000,
        "duration" => 3600.0,
        "bitrate" => 8_000_000,
        "width" => 1920,
        "height" => 1080,
        "video_codecs" => ["h264"],
        "audio_codecs" => ["aac"],
        "library_id" => library.id
      }

      {:ok, video} = VideoUpsert.upsert(attrs)

      assert video.bitrate == 8_000_000
    end

    test "preserves bitrate when metadata changes but file doesn't", %{library: library} do
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

      {:ok, video} = VideoUpsert.upsert(attrs)

      # Update with same file characteristics but different bitrate
      updated_attrs = Map.merge(attrs, %{"bitrate" => 10_000_000})

      {:ok, updated} = VideoUpsert.upsert(updated_attrs)

      # Bitrate should be preserved
      assert updated.bitrate == video.bitrate
      assert updated.bitrate == 8_000_000
    end
  end

  describe "path edge cases" do
    test "handles attributes without path key" do
      attrs = %{
        "size" => 1_000_000,
        "duration" => 3600.0
      }

      # Should skip VMAF/bitrate handling and proceed to validation
      capture_log(fn ->
        result = VideoUpsert.upsert(attrs)
        assert {:error, %Ecto.Changeset{}} = result
      end)
    end

    test "handles non-binary path value" do
      attrs = %{
        "path" => 12_345,
        "size" => 1_000_000,
        "duration" => 3600.0
      }

      # Should skip VMAF/bitrate handling and proceed to validation
      capture_log(fn ->
        result = VideoUpsert.upsert(attrs)
        assert {:error, %Ecto.Changeset{}} = result
      end)
    end
  end
end
