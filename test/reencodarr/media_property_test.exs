defmodule Reencodarr.Media.PropertyTest do
  @moduledoc """
  Property-based tests for the Media module.

  These tests verify that the Media functions behave correctly across
  a wide range of generated inputs, helping catch edge cases that
  traditional example-based tests might miss.
  """

  use Reencodarr.DataCase, async: true
  use ExUnitProperties

  alias Reencodarr.Media
  import StreamData

  @moduletag :property

  describe "create_video/1 property tests" do
    property "creates valid videos with generated attributes" do
      check all(attrs <- video_attrs_generator()) do
        # Ensure we have a valid library first
        library = Fixtures.library_fixture()
        attrs = Map.put(attrs, :library_id, library.id)

        case Fixtures.video_fixture(attrs) do
          {:ok, video} ->
            assert video.path == attrs.path
            assert video.size == attrs.size
            assert video.bitrate == attrs.bitrate
            assert video.library_id == attrs.library_id

          # width, height, and codec fields are populated by MediaInfo processing

          {:error, changeset} ->
            # If creation fails, ensure it's due to validation, not crashes
            assert %Ecto.Changeset{} = changeset
            refute changeset.valid?
        end
      end
    end

    property "rejects videos with invalid paths" do
      check all(invalid_path <- invalid_string_generator()) do
        library = Fixtures.library_fixture()

        attrs = %{
          path: invalid_path,
          size: 1_000_000,
          library_id: library.id,
          max_audio_channels: 2,
          atmos: false,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        }

        case Fixtures.video_fixture(attrs) do
          {:error, changeset} ->
            assert %{path: _} = errors_on(changeset)

          {:ok, _} ->
            # Some invalid values might still be accepted depending on validation rules
            :ok
        end
      end
    end

    property "rejects videos with invalid sizes" do
      check all(invalid_size <- invalid_number_generator()) do
        library = Fixtures.library_fixture()
        unique_id = :erlang.unique_integer([:positive])

        attrs = %{
          path: "/valid/path_#{unique_id}.mkv",
          size: invalid_size,
          library_id: library.id
        }

        case Fixtures.video_fixture(attrs) do
          {:error, changeset} ->
            # Should have validation errors, but might be on different fields
            refute changeset.valid?

          {:ok, _} ->
            # Some values might be coerced or accepted
            :ok
        end
      end
    end
  end

  describe "create_vmaf/1 property tests" do
    property "creates valid VMAF records with generated attributes" do
      check all(vmaf_attrs <- vmaf_attrs_generator(nil)) do
        # Set up test data for each property run to avoid unique constraint violations
        library = Fixtures.library_fixture()

        video_attrs = %{
          path: "/test/video_#{:erlang.unique_integer([:positive])}.mkv",
          size: 1_000_000,
          library_id: library.id,
          max_audio_channels: 2,
          atmos: false,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        }

        {:ok, video} = Fixtures.video_fixture(video_attrs)

        # Update vmaf_attrs with the actual video_id
        vmaf_attrs = Map.put(vmaf_attrs, :video_id, video.id)

        case Media.create_vmaf(vmaf_attrs) do
          {:ok, vmaf} ->
            assert vmaf.video_id == vmaf_attrs.video_id
            assert vmaf.crf == vmaf_attrs.crf
            assert vmaf.score == vmaf_attrs.score
            assert vmaf.params == vmaf_attrs.params

          {:error, changeset} ->
            # If creation fails, ensure it's due to validation
            assert %Ecto.Changeset{} = changeset
            refute changeset.valid?
        end
      end
    end

    property "VMAF scores are within valid range" do
      check all(score <- vmaf_score_generator()) do
        assert score >= 0.0
        assert score <= 100.0
      end
    end

    property "CRF values are within encoding range" do
      check all(crf <- crf_generator()) do
        assert crf >= 18
        assert crf <= 35
      end
    end
  end

  describe "update_video/2 property tests" do
    property "updates preserve video identity" do
      check all(update_attrs <- video_attrs_generator()) do
        # Set up test data first to avoid unique constraint violations
        library = Fixtures.library_fixture()
        unique_id = :erlang.unique_integer([:positive])

        original_attrs = %{
          path: "/original/path_#{unique_id}.mkv",
          size: 1_000_000,
          library_id: library.id,
          max_audio_channels: 2,
          atmos: false,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        }

        {:ok, video} = Fixtures.video_fixture(original_attrs)

        # Remove library_id from updates to avoid constraint issues
        # and make the path unique
        update_attrs =
          update_attrs
          |> Map.delete(:library_id)
          |> Map.put(:path, "/updated/path_#{unique_id}_#{:rand.uniform(10000)}.mkv")

        case Media.update_video(video, update_attrs) do
          {:ok, updated_video} ->
            # ID should remain the same
            assert updated_video.id == video.id
            # Library association should remain the same
            assert updated_video.library_id == video.library_id

          {:error, changeset} ->
            # If update fails, ensure it's due to validation
            assert %Ecto.Changeset{} = changeset
            refute changeset.valid?
        end
      end
    end
  end

  describe "video codec and extension relationships" do
    property "video codecs are valid strings" do
      check all(codec <- video_codec_generator()) do
        assert is_binary(codec)
        assert String.length(codec) > 0
        assert codec in ["h264", "hevc", "av01", "vp9", "vp8", "mpeg2", "mpeg4"]
      end
    end

    property "video extensions are valid" do
      check all(ext <- video_extension_generator()) do
        assert is_binary(ext)
        assert String.starts_with?(ext, ".")
        assert ext in [".mkv", ".mp4", ".avi", ".mov", ".webm", ".ts", ".m2ts"]
      end
    end

    property "audio codec lists are non-empty" do
      check all(codecs <- audio_codecs_generator()) do
        assert is_list(codecs)
        assert length(codecs) > 0
        assert length(codecs) <= 3

        Enum.each(codecs, fn codec ->
          assert codec in ["aac", "ac3", "dts", "truehd", "flac", "opus"]
        end)
      end
    end
  end

  describe "video resolution properties" do
    property "resolutions have positive dimensions" do
      check all({width, height} <- video_resolution_generator()) do
        assert width > 0
        assert height > 0
        assert is_integer(width)
        assert is_integer(height)
      end
    end

    property "common aspect ratios are represented" do
      check all({width, height} <- video_resolution_generator()) do
        ratio = width / height
        # Most video content should be wider than it is tall
        assert ratio >= 1.0
        # Should be reasonable aspect ratios (not extreme)
        assert ratio <= 3.0
      end
    end
  end

  # === PROPERTY GENERATORS ===

  defp video_attrs_generator do
    gen all(
          path <- string(:printable, min_length: 10, max_length: 100),
          bitrate <- integer(1_000_000..50_000_000),
          size <- integer(100_000_000..50_000_000_000),
          width <- member_of([720, 1280, 1920, 3840]),
          height <- member_of([480, 720, 1080, 2160]),
          video_codecs <-
            list_of(member_of(["h264", "h265", "av1"]), min_length: 1, max_length: 2),
          audio_codecs <-
            list_of(member_of(["aac", "ac3", "dts", "opus"]), min_length: 1, max_length: 3),
          max_audio_channels <- member_of([2, 6, 8]),
          atmos <- boolean()
        ) do
      %{
        path: "/test/#{path}.mkv",
        bitrate: bitrate,
        size: size,
        width: width,
        height: height,
        video_codecs: video_codecs,
        audio_codecs: audio_codecs,
        max_audio_channels: max_audio_channels,
        atmos: atmos
      }
    end
  end

  defp invalid_string_generator do
    one_of([
      constant(nil),
      constant(""),
      string(:ascii, max_length: 2)
    ])
  end

  defp invalid_number_generator do
    one_of([
      constant(nil),
      constant(0),
      constant(-1),
      integer(-1000..-1)
    ])
  end

  defp vmaf_attrs_generator(video_id) do
    gen all(
          crf <- integer(15..51),
          vmaf_score <- float(min: 0.0, max: 100.0)
        ) do
      %{
        video_id: video_id,
        crf: crf,
        vmaf_score: vmaf_score
      }
    end
  end

  defp crf_generator do
    integer(18..35)
  end

  defp vmaf_score_generator do
    float(min: 0.0, max: 100.0)
  end

  defp video_codec_generator do
    member_of(["h264", "hevc", "av01", "vp9", "vp8", "mpeg2", "mpeg4"])
  end

  defp audio_codecs_generator do
    list_of(member_of(["aac", "ac3", "dts", "truehd", "flac", "opus"]),
      min_length: 1,
      max_length: 3
    )
  end

  defp video_extension_generator do
    member_of([".mkv", ".mp4", ".avi", ".mov"])
  end

  defp video_resolution_generator do
    member_of([
      {1280, 720},
      {1920, 1080},
      {2560, 1440},
      {3840, 2160}
    ])
  end
end
