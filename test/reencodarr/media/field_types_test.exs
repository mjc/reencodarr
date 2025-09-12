defmodule Reencodarr.Media.FieldTypesTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Media.FieldTypes

  describe "get_field_type/2" do
    test "returns correct type for general track fields" do
      assert FieldTypes.get_field_type(:general, :FileSize) ==
               {:integer, min: 0, max: 1_000_000_000_000}

      assert FieldTypes.get_field_type(:general, :Duration) == {:float, min: 0.0, max: 86_400.0}
      assert FieldTypes.get_field_type(:general, :Title) == :string
    end

    test "returns correct type for video track fields" do
      assert FieldTypes.get_field_type(:video, :Width) == {:integer, min: 1, max: 8192}
      assert FieldTypes.get_field_type(:video, :Height) == {:integer, min: 1, max: 8192}
      assert FieldTypes.get_field_type(:video, :FrameRate) == {:float, min: 0.0, max: 120.0}
      assert FieldTypes.get_field_type(:video, :Format) == :string
    end

    test "returns correct type for audio track fields" do
      assert FieldTypes.get_field_type(:audio, :SamplingRate) ==
               {:integer, min: 8000, max: 192_000}

      assert FieldTypes.get_field_type(:audio, :Format) == :string
      assert FieldTypes.get_field_type(:audio, :Channels) == :string
    end

    test "returns correct type for text track fields" do
      assert FieldTypes.get_field_type(:text, :Format) == :string
      assert FieldTypes.get_field_type(:text, :Language) == :string
      assert FieldTypes.get_field_type(:text, :Duration) == {:float, min: 0.0, max: 86_400.0}
    end

    test "returns nil for unknown fields" do
      assert FieldTypes.get_field_type(:general, :UnknownField) == nil
      assert FieldTypes.get_field_type(:unknown_track, :SomeField) == nil
    end
  end

  describe "convert_and_validate/3" do
    test "converts and validates integer fields successfully" do
      assert FieldTypes.convert_and_validate(:general, :FileSize, "1024") == {:ok, 1024}
      assert FieldTypes.convert_and_validate(:general, :FileSize, 1024) == {:ok, 1024}
      assert FieldTypes.convert_and_validate(:general, :FileSize, 1024.0) == {:ok, 1024}
    end

    test "converts and validates float fields successfully" do
      assert FieldTypes.convert_and_validate(:general, :Duration, "123.456") == {:ok, 123.456}
      assert FieldTypes.convert_and_validate(:general, :Duration, 123.456) == {:ok, 123.456}
      assert FieldTypes.convert_and_validate(:general, :Duration, 123) == {:ok, 123.0}
    end

    test "converts and validates string fields successfully" do
      assert FieldTypes.convert_and_validate(:general, :Title, "Test Video") ==
               {:ok, "Test Video"}

      assert FieldTypes.convert_and_validate(:general, :Title, 123) == {:ok, "123"}
    end

    test "validates integer constraints" do
      # Within valid range
      assert FieldTypes.convert_and_validate(:video, :Width, "1920") == {:ok, 1920}

      # Below minimum
      assert {:error, {:validation_error, msg}} =
               FieldTypes.convert_and_validate(:video, :Width, "0")

      assert msg =~ "Width must be at least 1"

      # Above maximum
      assert {:error, {:validation_error, msg}} =
               FieldTypes.convert_and_validate(:video, :Width, "10000")

      assert msg =~ "Width must be at most 8192"
    end

    test "validates float constraints" do
      # Within valid range
      assert FieldTypes.convert_and_validate(:video, :FrameRate, "23.976") == {:ok, 23.976}

      # Below minimum (negative frame rate)
      assert {:error, {:validation_error, msg}} =
               FieldTypes.convert_and_validate(:video, :FrameRate, "-1.0")

      assert msg =~ "FrameRate must be at least 0.0"

      # Above maximum (impossible frame rate)
      assert {:error, {:validation_error, msg}} =
               FieldTypes.convert_and_validate(:video, :FrameRate, "200.0")

      assert msg =~ "FrameRate must be at most 120.0"
    end

    test "handles nil values gracefully" do
      assert FieldTypes.convert_and_validate(:general, :FileSize, nil) == {:ok, nil}
      assert FieldTypes.convert_and_validate(:video, :Width, nil) == {:ok, nil}
      assert FieldTypes.convert_and_validate(:general, :Title, nil) == {:ok, nil}
    end

    test "handles conversion errors" do
      assert {:error, {:conversion_error, msg}} =
               FieldTypes.convert_and_validate(:general, :FileSize, "not_a_number")

      assert msg =~ "FileSize"
      assert msg =~ "cannot convert"

      assert {:error, {:conversion_error, msg}} =
               FieldTypes.convert_and_validate(:general, :Duration, "invalid_float")

      assert msg =~ "Duration"
      assert msg =~ "cannot convert"
    end

    test "handles unknown fields by passing through" do
      assert FieldTypes.convert_and_validate(:general, :UnknownField, "some_value") ==
               {:ok, "some_value"}

      assert FieldTypes.convert_and_validate(:unknown_track, :SomeField, 123) == {:ok, 123}
    end
  end

  describe "validate_converted_value/3" do
    test "validates integer constraints correctly" do
      assert FieldTypes.validate_converted_value(1920, {:integer, min: 1, max: 8192}, :Width) ==
               :ok

      assert {:error, {:validation_error, msg}} =
               FieldTypes.validate_converted_value(0, {:integer, min: 1, max: 8192}, :Width)

      assert msg =~ "Width must be at least 1"

      assert {:error, {:validation_error, msg}} =
               FieldTypes.validate_converted_value(10_000, {:integer, min: 1, max: 8192}, :Width)

      assert msg =~ "Width must be at most 8192"
    end

    test "validates float constraints correctly" do
      assert FieldTypes.validate_converted_value(
               23.976,
               {:float, min: 0.0, max: 120.0},
               :FrameRate
             ) == :ok

      assert {:error, {:validation_error, msg}} =
               FieldTypes.validate_converted_value(
                 -1.0,
                 {:float, min: 0.0, max: 120.0},
                 :FrameRate
               )

      assert msg =~ "FrameRate must be at least 0.0"

      assert {:error, {:validation_error, msg}} =
               FieldTypes.validate_converted_value(
                 200.0,
                 {:float, min: 0.0, max: 120.0},
                 :FrameRate
               )

      assert msg =~ "FrameRate must be at most 120.0"
    end

    test "validates string constraints correctly" do
      # No constraints should pass
      assert FieldTypes.validate_converted_value("test", :string, :Title) == :ok

      # With length constraints (would be added if needed)
      assert FieldTypes.validate_converted_value("test", {:string, []}, :Title) == :ok
    end

    test "passes validation for types without constraints" do
      assert FieldTypes.validate_converted_value("test", :string, :Format) == :ok
      assert FieldTypes.validate_converted_value(true, :boolean, :Default) == :ok
    end
  end

  describe "get_all_field_types/1" do
    test "returns all field types for general track" do
      fields = FieldTypes.get_all_field_types(:general)
      assert Map.has_key?(fields, :FileSize)
      assert Map.has_key?(fields, :Duration)
      assert Map.has_key?(fields, :Title)
      assert map_size(fields) > 5
    end

    test "returns all field types for video track" do
      fields = FieldTypes.get_all_field_types(:video)
      assert Map.has_key?(fields, :Width)
      assert Map.has_key?(fields, :Height)
      assert Map.has_key?(fields, :FrameRate)
      assert map_size(fields) > 10
    end

    test "returns all field types for audio track" do
      fields = FieldTypes.get_all_field_types(:audio)
      assert Map.has_key?(fields, :SamplingRate)
      assert Map.has_key?(fields, :Format)
      assert map_size(fields) > 5
    end

    test "returns all field types for text track" do
      fields = FieldTypes.get_all_field_types(:text)
      assert Map.has_key?(fields, :Format)
      assert Map.has_key?(fields, :Language)
      assert map_size(fields) > 3
    end

    test "returns empty map for unknown track type" do
      assert FieldTypes.get_all_field_types(:unknown) == %{}
    end
  end

  describe "edge cases and error handling" do
    test "handles various number formats correctly" do
      # Note: Scientific notation parsing is limited by Integer.parse behavior
      # "1.5e3" parses as 1 (only the integer part before the decimal)
      assert FieldTypes.convert_and_validate(:general, :FileSize, "1.5e3") == {:ok, 1}

      # Large numbers work fine
      assert FieldTypes.convert_and_validate(:general, :FileSize, "1000000000") ==
               {:ok, 1_000_000_000}

      # Decimal strings for integers (truncated)
      assert FieldTypes.convert_and_validate(:general, :VideoCount, "2.0") == {:ok, 2}
    end

    test "handles edge case values" do
      # Zero values where valid
      assert FieldTypes.convert_and_validate(:general, :OverallBitRate, "0") == {:ok, 0}
      assert FieldTypes.convert_and_validate(:general, :Duration, "0.0") == {:ok, 0.0}

      # Maximum valid values
      assert FieldTypes.convert_and_validate(:video, :Width, "8192") == {:ok, 8192}
      assert FieldTypes.convert_and_validate(:video, :Height, "8192") == {:ok, 8192}
    end

    test "provides clear error messages for boundary violations" do
      {:error, {:validation_error, msg}} =
        FieldTypes.convert_and_validate(:audio, :SamplingRate, "7999")

      assert msg =~ "SamplingRate must be at least 8000"

      {:error, {:validation_error, msg}} =
        FieldTypes.convert_and_validate(:audio, :SamplingRate, "200000")

      assert msg =~ "SamplingRate must be at most 192000"
    end

    test "handles malformed input gracefully" do
      # Empty strings
      assert {:error, {:conversion_error, _}} =
               FieldTypes.convert_and_validate(:general, :FileSize, "")

      # Special characters - Note: Integer.parse("1@#$") returns {1, "@#$"} so it parses as 1
      assert {:ok, 1} = FieldTypes.convert_and_validate(:general, :FileSize, "1@#$")

      # Multiple decimal points - Note: Float.parse("1.2.3") returns {1.2, ".3"} so it parses as 1.2
      assert {:ok, 1.2} = FieldTypes.convert_and_validate(:general, :Duration, "1.2.3")
    end
  end

  describe "real-world data scenarios" do
    test "handles typical MediaInfo values correctly" do
      # Common video resolutions
      assert FieldTypes.convert_and_validate(:video, :Width, "1920") == {:ok, 1920}
      assert FieldTypes.convert_and_validate(:video, :Height, "1080") == {:ok, 1080}
      assert FieldTypes.convert_and_validate(:video, :Width, "3840") == {:ok, 3840}
      assert FieldTypes.convert_and_validate(:video, :Height, "2160") == {:ok, 2160}

      # Common frame rates
      assert FieldTypes.convert_and_validate(:video, :FrameRate, "23.976") == {:ok, 23.976}
      assert FieldTypes.convert_and_validate(:video, :FrameRate, "24.000") == {:ok, 24.0}
      assert FieldTypes.convert_and_validate(:video, :FrameRate, "29.970") == {:ok, 29.97}

      # Common audio sampling rates
      assert FieldTypes.convert_and_validate(:audio, :SamplingRate, "48000") == {:ok, 48_000}
      assert FieldTypes.convert_and_validate(:audio, :SamplingRate, "44100") == {:ok, 44_100}
      assert FieldTypes.convert_and_validate(:audio, :SamplingRate, "96000") == {:ok, 96_000}

      # Typical file sizes (in bytes)
      # 1GB
      assert FieldTypes.convert_and_validate(:general, :FileSize, "1073741824") ==
               {:ok, 1_073_741_824}

      # 5GB
      assert FieldTypes.convert_and_validate(:general, :FileSize, "5368709120") ==
               {:ok, 5_368_709_120}
    end

    test "handles duration values from MediaInfo" do
      # Short clips
      assert FieldTypes.convert_and_validate(:general, :Duration, "30.500") == {:ok, 30.5}

      # TV episodes (~45 minutes)
      assert FieldTypes.convert_and_validate(:general, :Duration, "2700.000") == {:ok, 2700.0}

      # Movies (~2 hours)
      assert FieldTypes.convert_and_validate(:general, :Duration, "7200.000") == {:ok, 7200.0}
    end

    test "rejects unrealistic values that could indicate data corruption" do
      # Impossibly large resolutions
      assert {:error, _} = FieldTypes.convert_and_validate(:video, :Width, "99999")
      assert {:error, _} = FieldTypes.convert_and_validate(:video, :Height, "99999")

      # Impossibly high frame rates
      assert {:error, _} = FieldTypes.convert_and_validate(:video, :FrameRate, "999.0")

      # Impossibly long durations (more than 24 hours)
      assert {:error, _} = FieldTypes.convert_and_validate(:general, :Duration, "90000.0")

      # Negative values where they don't make sense
      assert {:error, _} = FieldTypes.convert_and_validate(:general, :FileSize, "-1")
      assert {:error, _} = FieldTypes.convert_and_validate(:video, :Width, "-100")
    end
  end
end
