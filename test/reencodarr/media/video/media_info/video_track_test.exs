defmodule Reencodarr.Media.Video.MediaInfo.VideoTrackTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video.MediaInfo.VideoTrack

  defp valid_attrs do
    %{
      "Format" => "AVC",
      "Width" => "1920",
      "Height" => "1080"
    }
  end

  defp valid_attrs_hdr do
    %{
      "Format" => "HEVC",
      "Width" => "3840",
      "Height" => "2160",
      "colour_primaries" => "BT.2020",
      "transfer_characteristics" => "PQ",
      "matrix_coefficients" => "BT.2020 non-constant",
      "HDR_Format" => "SMPTE ST 2086",
      "HDR_Format_Commercial" => "HDR10"
    }
  end

  describe "changeset/2 - valid data" do
    test "valid attrs produce valid changeset" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs())
      assert changeset.valid?
    end

    test "stores raw_data as virtual field" do
      attrs = valid_attrs()
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :raw_data) == attrs
    end

    test "maps Format key to format field" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :format) == "AVC"
    end

    test "maps Width string to width integer" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :width) == 1920
    end

    test "maps Height string to height integer" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :height) == 1080
    end

    test "maps FrameRate string value" do
      attrs = Map.put(valid_attrs(), "FrameRate", "23.976")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert is_float(Ecto.Changeset.get_change(changeset, :frame_rate))
    end

    test "maps BitRate numeric value" do
      attrs = Map.put(valid_attrs(), "BitRate", 5_000_000)
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :bit_rate) == 5_000_000
    end

    test "maps Duration numeric value" do
      attrs = Map.put(valid_attrs(), "Duration", 7200.0)
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :duration) == 7200.0
    end

    test "maps Format_Profile key to format_profile field" do
      attrs = Map.put(valid_attrs(), "Format_Profile", "High@L4.0")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :format_profile) == "High@L4.0"
    end

    test "maps ColorSpace field" do
      attrs = Map.put(valid_attrs(), "ColorSpace", "YUV")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :color_space) == "YUV"
    end

    test "maps DisplayAspectRatio field" do
      attrs = Map.put(valid_attrs(), "DisplayAspectRatio", "16:9")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :display_aspect_ratio) == "16:9"
    end

    test "maps ScanType field" do
      attrs = Map.put(valid_attrs(), "ScanType", "Progressive")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :scan_type) == "Progressive"
    end
  end

  describe "changeset/2 - HDR fields" do
    test "valid HDR attrs produce valid changeset" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs_hdr())
      assert changeset.valid?
    end

    test "maps colour_primaries (lowercase) to color_primaries" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs_hdr())
      assert Ecto.Changeset.get_change(changeset, :color_primaries) == "BT.2020"
    end

    test "maps transfer_characteristics to transfer_characteristics field" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs_hdr())
      assert Ecto.Changeset.get_change(changeset, :transfer_characteristics) == "PQ"
    end

    test "maps matrix_coefficients field" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs_hdr())

      assert Ecto.Changeset.get_change(changeset, :matrix_coefficients) ==
               "BT.2020 non-constant"
    end

    test "maps HDR_Format to hdr_format field" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs_hdr())
      assert Ecto.Changeset.get_change(changeset, :hdr_format) == "SMPTE ST 2086"
    end

    test "maps HDR_Format_Commercial to hdr_format_commercial field" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs_hdr())
      assert Ecto.Changeset.get_change(changeset, :hdr_format_commercial) == "HDR10"
    end

    test "SDR video has nil HDR fields" do
      changeset = VideoTrack.changeset(%VideoTrack{}, valid_attrs())
      assert is_nil(Ecto.Changeset.get_change(changeset, :hdr_format))
      assert is_nil(Ecto.Changeset.get_change(changeset, :color_primaries))
    end
  end

  describe "changeset/2 - validation errors" do
    test "missing format is invalid" do
      attrs = Map.delete(valid_attrs(), "Format")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute changeset.valid?
    end

    test "missing width is invalid (fails resolution validation)" do
      attrs = Map.delete(valid_attrs(), "Width")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute changeset.valid?
    end

    test "missing height is invalid (fails resolution validation)" do
      attrs = Map.delete(valid_attrs(), "Height")
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute changeset.valid?
    end

    test "empty attrs produce invalid changeset" do
      changeset = VideoTrack.changeset(%VideoTrack{}, %{})
      refute changeset.valid?
    end
  end

  describe "changeset/2 - snake_case keys" do
    test "accepts lowercase snake_case format key" do
      attrs = %{"format" => "VP9", "width" => "1280", "height" => "720"}
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :format) == "VP9"
    end

    test "accepts snake_case width and height" do
      attrs = %{"format" => "AV1", "width" => "3840", "height" => "2160"}
      changeset = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :width) == 3840
      assert Ecto.Changeset.get_change(changeset, :height) == 2160
    end
  end
end
