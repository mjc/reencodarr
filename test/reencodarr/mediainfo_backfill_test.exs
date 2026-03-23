defmodule Reencodarr.MediaInfoBackfillTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.Media

  describe "backfill_missing_mediainfo/1" do
    test "fills missing mediainfo without resetting video state" do
      {:ok, missing_video} =
        Fixtures.video_fixture(%{
          path: "/media/backfill-missing.mkv",
          state: :encoded,
          bitrate: 4_000_000,
          mediainfo: nil
        })

      {:ok, existing_video} =
        Fixtures.video_fixture(%{
          path: "/media/backfill-existing.mkv",
          state: :failed,
          bitrate: 5_000_000,
          mediainfo: source_mediainfo("AAC", 2, "L R")
        })

      assert {:ok, summary} =
               Media.backfill_missing_mediainfo(
                 batch_probe_fun: fn paths ->
                   assert paths == ["/media/backfill-missing.mkv"]

                   {:ok,
                    %{
                      "/media/backfill-missing.mkv" => source_mediainfo("E-AC-3", 6, "5.1(side)")
                    }}
                 end
               )

      assert summary.scanned == 1
      assert summary.backfilled == 1
      assert summary.failed == 0

      refreshed_missing = Media.get_video!(missing_video.id)
      refreshed_existing = Media.get_video!(existing_video.id)

      assert refreshed_missing.state == :encoded
      assert refreshed_missing.bitrate == 4_000_000
      assert get_in(refreshed_missing.mediainfo, ["media", "track"]) != nil

      assert refreshed_existing.state == :failed
      assert refreshed_existing.bitrate == existing_video.bitrate
      assert refreshed_existing.mediainfo == existing_video.mediainfo
    end

    test "counts probe failures without resetting affected rows" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/media/backfill-failure.mkv",
          state: :encoded,
          mediainfo: nil
        })

      assert {:ok, summary} =
               Media.backfill_missing_mediainfo(
                 batch_probe_fun: fn ["/media/backfill-failure.mkv"] ->
                   {:error, :mediainfo_failed}
                 end
               )

      assert summary.scanned == 1
      assert summary.backfilled == 0
      assert summary.failed == 1

      refreshed_video = Media.get_video!(video.id)
      assert refreshed_video.state == :encoded
      assert refreshed_video.mediainfo == nil
    end
  end

  defp source_mediainfo(format, channels, layout) do
    %{
      "media" => %{
        "track" => [
          %{"@type" => "General", "Duration" => "7200.0", "OverallBitRate" => "4000000"},
          %{
            "@type" => "Video",
            "Format" => "AVC",
            "CodecID" => "V_MPEG4/ISO/AVC",
            "Width" => "1920",
            "Height" => "1080"
          },
          %{
            "@type" => "Audio",
            "Format" => format,
            "CodecID" => format,
            "Channels" => Integer.to_string(channels),
            "ChannelLayout" => layout,
            "Default" => "Yes"
          }
        ]
      }
    }
  end
end
