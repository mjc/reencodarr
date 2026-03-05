defmodule Reencodarr.Media.Video.MediaInfo.GeneralTrackTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video.MediaInfo.GeneralTrack

  defp valid_attrs do
    %{
      "Duration" => 3600.0,
      "Format" => "Matroska",
      "FileSize" => 10_737_418_240
    }
  end

  describe "changeset/2 - valid data" do
    test "valid attrs produce valid changeset" do
      changeset = GeneralTrack.changeset(%GeneralTrack{}, valid_attrs())
      assert changeset.valid?
    end

    test "stores raw_data as virtual field" do
      attrs = valid_attrs()
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :raw_data) == attrs
    end

    test "maps Duration to duration field" do
      changeset = GeneralTrack.changeset(%GeneralTrack{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :duration) == 3600.0
    end

    test "maps Duration string value" do
      attrs = Map.put(valid_attrs(), "Duration", "90000.0")
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert is_float(Ecto.Changeset.get_change(changeset, :duration))
    end

    test "maps FileSize to file_size field" do
      changeset = GeneralTrack.changeset(%GeneralTrack{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :file_size) == 10_737_418_240
    end

    test "maps Format to format field" do
      changeset = GeneralTrack.changeset(%GeneralTrack{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :format) == "Matroska"
    end

    test "maps Format_Profile to format_profile field" do
      attrs = Map.put(valid_attrs(), "Format_Profile", "Version 4")
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :format_profile) == "Version 4"
    end

    test "maps FileExtension to file_extension field" do
      attrs = Map.put(valid_attrs(), "FileExtension", "mkv")
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :file_extension) == "mkv"
    end

    test "maps MovieName to movie_name field" do
      attrs = Map.put(valid_attrs(), "MovieName", "Interstellar")
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :movie_name) == "Interstellar"
    end

    test "maps OverallBitRate to overall_bit_rate field" do
      attrs = Map.put(valid_attrs(), "OverallBitRate", 8_500_000)
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :overall_bit_rate) == 8_500_000
    end
  end

  describe "changeset/2 - validation errors" do
    test "missing duration is invalid" do
      attrs = Map.delete(valid_attrs(), "Duration")
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      refute changeset.valid?
    end

    test "empty attrs produce invalid changeset" do
      changeset = GeneralTrack.changeset(%GeneralTrack{}, %{})
      refute changeset.valid?
    end
  end

  describe "changeset/2 - snake_case keys" do
    test "accepts lowercase snake_case duration key" do
      attrs = %{"duration" => 1800.0, "format" => "MP4"}
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :duration) == 1800.0
    end

    test "accepts snake_case file_size key" do
      attrs = %{"duration" => 1800.0, "file_size" => 5_368_709_120}
      changeset = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :file_size) == 5_368_709_120
    end
  end
end
