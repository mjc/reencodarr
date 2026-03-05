defmodule Reencodarr.ValidationTest do
  use Reencodarr.UnitCase, async: true

  import Ecto.Changeset
  alias Reencodarr.Validation

  # Minimal schema stub for building changesets in tests
  defmodule TestSchema do
    use Ecto.Schema

    embedded_schema do
      field :name, :string
      field :count, :integer
      field :ratio, :float
      field :width, :integer
      field :height, :integer
      field :channels, :integer
      field :format, :string
      field :bitrate, :integer
    end
  end

  defp changeset(attrs) do
    cast(%TestSchema{}, attrs, [
      :name,
      :count,
      :ratio,
      :width,
      :height,
      :channels,
      :format,
      :bitrate
    ])
  end

  # ---------------------------------------------------------------------------
  # validate_required_field/3
  # ---------------------------------------------------------------------------

  describe "validate_required_field/3" do
    test "passes when field is present" do
      cs = changeset(%{name: "hello"}) |> Validation.validate_required_field(:name)
      assert cs.valid?
    end

    test "adds error when field is nil (not cast)" do
      cs = changeset(%{}) |> Validation.validate_required_field(:name)
      refute cs.valid?
      assert cs.errors[:name] != nil
    end

    test "uses custom message when provided" do
      cs = changeset(%{}) |> Validation.validate_required_field(:name, "custom message")
      assert {"custom message", []} = cs.errors[:name]
    end

    test "default message includes field name" do
      cs = changeset(%{}) |> Validation.validate_required_field(:name)
      {msg, _} = cs.errors[:name]
      assert String.contains?(msg, "name")
    end
  end

  # ---------------------------------------------------------------------------
  # validate_positive_number/3
  # ---------------------------------------------------------------------------

  describe "validate_positive_number/3" do
    test "passes when field is positive" do
      cs = changeset(%{count: 5}) |> Validation.validate_positive_number(:count)
      assert cs.valid?
    end

    test "passes when field is nil (not set)" do
      cs = changeset(%{}) |> Validation.validate_positive_number(:count)
      assert cs.valid?
    end

    test "adds error when value is 0" do
      cs = changeset(%{count: 0}) |> Validation.validate_positive_number(:count)
      refute cs.valid?
      assert cs.errors[:count] != nil
    end

    test "adds error when value is negative" do
      cs = changeset(%{count: -1}) |> Validation.validate_positive_number(:count)
      refute cs.valid?
    end

    test "uses custom message" do
      cs =
        changeset(%{count: -5})
        |> Validation.validate_positive_number(:count, "must be > 0")

      assert {"must be > 0", []} = cs.errors[:count]
    end
  end

  # ---------------------------------------------------------------------------
  # validate_number_range/5
  # ---------------------------------------------------------------------------

  describe "validate_number_range/5" do
    test "passes when value is within range" do
      cs = changeset(%{ratio: 0.5}) |> Validation.validate_number_range(:ratio, 0.0, 1.0)
      assert cs.valid?
    end

    test "passes at exact min boundary" do
      cs = changeset(%{ratio: 0.0}) |> Validation.validate_number_range(:ratio, 0.0, 1.0)
      assert cs.valid?
    end

    test "passes at exact max boundary" do
      cs = changeset(%{ratio: 1.0}) |> Validation.validate_number_range(:ratio, 0.0, 1.0)
      assert cs.valid?
    end

    test "passes when field is nil" do
      cs = changeset(%{}) |> Validation.validate_number_range(:ratio, 0.0, 1.0)
      assert cs.valid?
    end

    test "adds error when below min" do
      cs = changeset(%{ratio: -0.1}) |> Validation.validate_number_range(:ratio, 0.0, 1.0)
      refute cs.valid?
      assert cs.errors[:ratio] != nil
    end

    test "adds error when above max" do
      cs = changeset(%{ratio: 1.1}) |> Validation.validate_number_range(:ratio, 0.0, 1.0)
      refute cs.valid?
    end

    test "uses custom message" do
      cs =
        changeset(%{count: 9999})
        |> Validation.validate_number_range(:count, 1, 100, "out of range")

      assert {"out of range", []} = cs.errors[:count]
    end
  end

  # ---------------------------------------------------------------------------
  # validate_not_empty/3
  # ---------------------------------------------------------------------------

  describe "validate_not_empty/3" do
    test "passes for non-empty string" do
      cs = changeset(%{name: "hello"}) |> Validation.validate_not_empty(:name)
      assert cs.valid?
    end

    test "adds error for blank string" do
      # Use put_change to bypass Ecto's cast which converts whitespace-only to nil
      cs =
        changeset(%{})
        |> Ecto.Changeset.put_change(:name, "   ")
        |> Validation.validate_not_empty(:name)

      refute cs.valid?
    end

    test "adds error for zero numeric value" do
      cs = changeset(%{count: 0}) |> Validation.validate_not_empty(:count)
      refute cs.valid?
    end

    test "passes for nil (field not set)" do
      cs = changeset(%{}) |> Validation.validate_not_empty(:name)
      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # validate_video_resolution/1
  # ---------------------------------------------------------------------------

  describe "validate_video_resolution/1" do
    test "passes for valid width and height" do
      cs = changeset(%{width: 1920, height: 1080}) |> Validation.validate_video_resolution()
      assert cs.valid?
    end

    test "adds error when width is nil" do
      cs = changeset(%{height: 1080}) |> Validation.validate_video_resolution()
      refute cs.valid?
      assert cs.errors[:width] != nil
    end

    test "adds error when height is nil" do
      cs = changeset(%{width: 1920}) |> Validation.validate_video_resolution()
      refute cs.valid?
      assert cs.errors[:height] != nil
    end

    test "adds error for non-positive width" do
      cs = changeset(%{width: 0, height: 1080}) |> Validation.validate_video_resolution()
      refute cs.valid?
    end

    test "adds error for non-positive height" do
      cs = changeset(%{width: 1920, height: -1}) |> Validation.validate_video_resolution()
      refute cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # validate_audio_channels/1
  # ---------------------------------------------------------------------------

  describe "validate_audio_channels/1" do
    test "passes for reasonable channel count" do
      cs = changeset(%{channels: 2}) |> Validation.validate_audio_channels()
      assert cs.valid?

      cs = changeset(%{channels: 8}) |> Validation.validate_audio_channels()
      assert cs.valid?
    end

    test "adds error when channels is nil" do
      cs = changeset(%{}) |> Validation.validate_audio_channels()
      refute cs.valid?
    end

    test "adds error when channels <= 0" do
      cs = changeset(%{channels: 0}) |> Validation.validate_audio_channels()
      refute cs.valid?
    end

    test "adds error when channels > 32 (unrealistic)" do
      cs = changeset(%{channels: 33}) |> Validation.validate_audio_channels()
      refute cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # validate_track_consistency/2
  # ---------------------------------------------------------------------------

  describe "validate_track_consistency/2" do
    test "skips checks when format is nil" do
      cs =
        changeset(%{bitrate: 0})
        |> Validation.validate_track_consistency(bitrate: "bitrate must not be zero")

      assert cs.valid?
    end

    test "skips checks when format is blank string" do
      cs =
        changeset(%{format: "   ", bitrate: 0})
        |> Validation.validate_track_consistency(bitrate: "bitrate must not be zero")

      assert cs.valid?
    end

    test "adds error when format present and checked field is 0" do
      cs =
        changeset(%{format: "AAC", bitrate: 0})
        |> Validation.validate_track_consistency(bitrate: "bitrate must not be zero")

      refute cs.valid?
      assert cs.errors[:bitrate] != nil
    end

    test "passes when format present and checked field is non-zero" do
      cs =
        changeset(%{format: "AAC", bitrate: 128})
        |> Validation.validate_track_consistency(bitrate: "bitrate must not be zero")

      assert cs.valid?
    end

    test "uses default empty field_checks" do
      cs = changeset(%{format: "AAC"}) |> Validation.validate_track_consistency()
      assert cs.valid?
    end
  end
end
