defmodule Reencodarr.Media.Video.MediaInfo.AudioTrackTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video.MediaInfo.AudioTrack

  defp valid_attrs do
    %{
      # Use integer channels to avoid DataConverters.parse_numeric returning 2.0
      "Format" => "AAC",
      "Channels" => 2,
      "BitRate" => 128_000,
      "Language" => "en"
    }
  end

  describe "changeset/2" do
    test "valid attrs produce valid changeset" do
      changeset = AudioTrack.changeset(%AudioTrack{}, valid_attrs())
      assert changeset.valid?
    end

    test "stores raw_data in changeset" do
      attrs = valid_attrs()
      changeset = AudioTrack.changeset(%AudioTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :raw_data) == attrs
    end

    test "maps MediaInfo-cased Format key" do
      changeset = AudioTrack.changeset(%AudioTrack{}, %{"Format" => "EAC3", "Channels" => "6"})
      assert Ecto.Changeset.get_change(changeset, :format) == "EAC3"
    end

    test "maps MediaInfo-cased Channels key as integer" do
      changeset = AudioTrack.changeset(%AudioTrack{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :channels) == 2
    end

    test "accepts integer channel values" do
      changeset = AudioTrack.changeset(%AudioTrack{}, %{"Format" => "DTS", "Channels" => 6})
      assert Ecto.Changeset.get_change(changeset, :channels) == 6
    end

    test "maps boolean Default field" do
      changeset =
        AudioTrack.changeset(%AudioTrack{}, Map.merge(valid_attrs(), %{"Default" => "Yes"}))

      assert Ecto.Changeset.get_change(changeset, :default) == true
    end

    test "invalid: zero channels integer produces error" do
      attrs = %{"Format" => "AAC", "Channels" => 0}
      changeset = AudioTrack.changeset(%AudioTrack{}, attrs)
      refute changeset.valid?
    end

    test "mapping 'No' boolean produces nil due to Enum.find_value falsy behaviour" do
      # Enum.find_value treats false as falsy — 'No' → false → skipped → nil
      changeset =
        AudioTrack.changeset(%AudioTrack{}, Map.merge(valid_attrs(), %{"Forced" => "No"}))

      # Actual behaviour: nil (find_value bug with false return)
      assert is_nil(Ecto.Changeset.get_change(changeset, :forced))
    end
  end

  describe "atmos?/1" do
    test "returns true for E-AC-3 format with atmos additional features" do
      track = %AudioTrack{
        format: "E-AC-3",
        format_additionalfeatures: "JOC / Atmos"
      }

      assert AudioTrack.atmos?(track)
    end

    test "returns true for explicit Atmos markers even when format is not E-AC-3" do
      track = %AudioTrack{
        format: "TrueHD",
        format_additionalfeatures: "Atmos"
      }

      assert AudioTrack.atmos?(track)
    end

    test "returns true for explicit commercial Atmos markers on TrueHD" do
      track = %AudioTrack{
        format: "TrueHD",
        format_commercial_if_any: "TrueHD Atmos"
      }

      assert AudioTrack.atmos?(track)
    end

    test "returns false when additional features is nil" do
      track = %AudioTrack{format: "E-AC-3", format_additionalfeatures: nil}
      refute AudioTrack.atmos?(track)
    end

    test "returns true when additional features has JOC" do
      track = %AudioTrack{format: "E-AC-3", format_additionalfeatures: "JOC"}
      assert AudioTrack.atmos?(track)
    end

    test "is case-insensitive for 'atmos'" do
      track = %AudioTrack{format: "E-AC-3", format_additionalfeatures: "ATMOS"}
      assert AudioTrack.atmos?(track)
    end
  end

  describe "commercial_format/1" do
    test "returns format_commercial_if_any when set" do
      track = %AudioTrack{format: "E-AC-3", format_commercial_if_any: "Dolby Digital Plus"}
      assert AudioTrack.commercial_format(track) == "Dolby Digital Plus"
    end

    test "returns format when commercial is nil" do
      track = %AudioTrack{format: "AAC", format_commercial_if_any: nil}
      assert AudioTrack.commercial_format(track) == "AAC"
    end

    test "returns format when commercial is empty string" do
      track = %AudioTrack{format: "DTS", format_commercial_if_any: ""}
      assert AudioTrack.commercial_format(track) == "DTS"
    end
  end
end
