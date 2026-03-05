defmodule Reencodarr.Media.VideoTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video

  defp valid_attrs do
    %{
      path: "/media/show/S01E01.mkv",
      state: :needs_analysis,
      size: 1_500_000_000
    }
  end

  defp analysis_attrs do
    Map.merge(valid_attrs(), %{
      video_codecs: ["HEVC"],
      audio_codecs: ["AAC"],
      max_audio_channels: 2,
      atmos: false
    })
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Video.changeset(%Video{}, valid_attrs())
      assert cs.valid?
    end

    test "missing path makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.delete(valid_attrs(), :path))
      refute cs.valid?
      assert {:path, _} = hd(cs.errors)
    end

    test "state defaults to :needs_analysis when not provided" do
      cs = Video.changeset(%Video{}, Map.delete(valid_attrs(), :state))
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :state) == :needs_analysis
    end

    test "missing size makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.delete(valid_attrs(), :size))
      refute cs.valid?
    end

    test "invalid state enum makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :state, :unknown_state))
      refute cs.valid?
    end

    test "invalid service_type makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :service_type, :plex))
      refute cs.valid?
    end

    test "valid service_type :sonarr is accepted" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :service_type, :sonarr))
      assert cs.valid?
    end

    test "valid service_type :radarr is accepted" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :service_type, :radarr))
      assert cs.valid?
    end

    test "bitrate of 0 is removed from changeset" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :bitrate, 0))
      assert cs.valid?
      # bitrate 0 is stripped, not cast
      refute Map.has_key?(cs.changes, :bitrate)
    end

    test "bitrate below 1 makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :bitrate, -1))
      refute cs.valid?
    end

    test "bitrate 1 or above is valid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :bitrate, 5_000_000))
      assert cs.valid?
    end

    test "audio_count > 0 with empty audio_codecs makes changeset invalid" do
      attrs =
        valid_attrs()
        |> Map.put(:audio_count, 2)
        |> Map.put(:audio_codecs, [])

      cs = Video.changeset(%Video{}, attrs)
      refute cs.valid?
    end

    test "audio_count > 0 with non-empty audio_codecs is valid" do
      attrs =
        valid_attrs()
        |> Map.put(:audio_count, 2)
        |> Map.put(:audio_codecs, ["AAC"])

      cs = Video.changeset(%Video{}, attrs)
      assert cs.valid?
    end

    test "max_audio_channels of 32 or above makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :max_audio_channels, 32))
      refute cs.valid?
    end

    test "max_audio_channels below 0 makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :max_audio_channels, -1))
      refute cs.valid?
    end

    test "max_audio_channels of 0 is valid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :max_audio_channels, 0))
      assert cs.valid?
    end

    test "empty path makes changeset invalid" do
      cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :path, ""))
      refute cs.valid?
    end

    test "all valid states are accepted" do
      for state <- [
            :needs_analysis,
            :analyzed,
            :crf_searching,
            :crf_searched,
            :encoding,
            :encoded,
            :failed
          ] do
        cs = Video.changeset(%Video{}, Map.put(valid_attrs(), :state, state))
        assert cs.valid?, "Expected state #{state} to be valid"
      end
    end
  end

  describe "analysis_changeset/2" do
    test "valid analysis attrs produce a valid changeset" do
      cs = Video.analysis_changeset(%Video{}, analysis_attrs())
      assert cs.valid?
    end

    test "video_codecs defaults to empty list (not a required failure) when missing" do
      # video_codecs has default: [] so validate_required passes even without providing it
      cs = Video.analysis_changeset(%Video{}, Map.delete(analysis_attrs(), :video_codecs))
      assert cs.valid?
    end

    test "audio_codecs defaults to empty list (not a required failure) when missing" do
      # audio_codecs has default: [] so validate_required passes even without providing it
      cs = Video.analysis_changeset(%Video{}, Map.delete(analysis_attrs(), :audio_codecs))
      assert cs.valid?
    end

    test "missing max_audio_channels makes analysis_changeset invalid" do
      cs = Video.analysis_changeset(%Video{}, Map.delete(analysis_attrs(), :max_audio_channels))
      refute cs.valid?
    end

    test "missing atmos makes analysis_changeset invalid" do
      cs = Video.analysis_changeset(%Video{}, Map.delete(analysis_attrs(), :atmos))
      refute cs.valid?
    end

    test "valid attrs with full analysis data is valid" do
      attrs =
        analysis_attrs()
        |> Map.put(:width, 1920)
        |> Map.put(:height, 1080)
        |> Map.put(:bitrate, 5_000_000)
        |> Map.put(:frame_rate, 24.0)
        |> Map.put(:duration, 3600.0)

      cs = Video.analysis_changeset(%Video{}, attrs)
      assert cs.valid?
    end
  end
end
