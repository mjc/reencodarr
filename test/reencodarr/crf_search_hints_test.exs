defmodule Reencodarr.CrfSearchHintsTest do
  @moduledoc """
  Tests for CrfSearchHints - season-aware CRF range narrowing.

  When episodes in the same season have the same resolution and HDR status,
  their optimal CRF values tend to cluster. CrfSearchHints uses this to
  narrow the search range for subsequent episodes, falling back to the
  standard range on retry.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.CrfSearchHints
  alias Reencodarr.Media

  @default_range {5, 70}

  describe "crf_range/2" do
    test "returns default range when no siblings exist" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Alone Show/Season 01/Alone.Show.S01E01.mkv",
          state: :analyzed
        })

      assert CrfSearchHints.crf_range(video) == @default_range
    end

    test "returns default range on retry regardless of siblings" do
      # Create 3 sibling episodes with chosen VMAFs
      videos = create_season_siblings("Retried Show", 1, 3, %{height: 1080, width: 1920})
      add_chosen_vmafs(videos, [20.0, 22.0, 21.0])

      # Create the video under test in the same season
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Retried Show/Season 01/Retried.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      assert CrfSearchHints.crf_range(video, retry: true) == @default_range
    end

    test "returns narrowed range from sibling CRFs" do
      videos = create_season_siblings("Good Show", 2, 3, %{height: 1080, width: 1920})
      add_chosen_vmafs(videos, [20.0, 24.0, 22.0])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Good Show/Season 02/Good.Show.S02E04.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      {min_crf, max_crf} = CrfSearchHints.crf_range(video)

      # min should be min_sibling - margin, max should be max_sibling + margin
      # Siblings: 20, 22, 24. With margin 6: range should be ~14-30
      assert min_crf < 20
      assert max_crf > 24
      # But still within absolute bounds
      assert min_crf >= 8
      assert max_crf <= 55
    end

    test "narrowed range is clamped to absolute bounds" do
      # Siblings with very low CRFs
      videos = create_season_siblings("Low CRF Show", 1, 2, %{height: 2160, width: 3840})
      add_chosen_vmafs(videos, [9.0, 10.0])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Low CRF Show/Season 01/Low.CRF.Show.S01E03.mkv",
          height: 2160,
          width: 3840,
          state: :analyzed
        })

      {min_crf, _max_crf} = CrfSearchHints.crf_range(video)
      assert min_crf >= 8
    end

    test "returns default range for movies (no season folder)" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/movies/Some Movie (2024)/Some.Movie.2024.mkv",
          state: :analyzed
        })

      assert CrfSearchHints.crf_range(video) == @default_range
    end
  end

  describe "sibling_crfs/1" do
    test "finds videos in same season folder with chosen VMAFs" do
      videos = create_season_siblings("Test Show", 1, 3, %{height: 1080, width: 1920})
      add_chosen_vmafs(videos, [18.0, 22.0, 25.0])

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Test Show/Season 01/Test.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      crfs = CrfSearchHints.sibling_crfs(target)
      assert length(crfs) == 3
      assert Enum.sort(crfs) == [18.0, 22.0, 25.0]
    end

    test "filters out siblings with different resolution" do
      # Create 1080p siblings with VMAFs
      videos_1080 = create_season_siblings("Mixed Res Show", 1, 2, %{height: 1080, width: 1920})
      add_chosen_vmafs(videos_1080, [20.0, 22.0])

      # Create a 4K sibling with VMAF (should be excluded)
      {:ok, video_4k} =
        Fixtures.video_fixture(%{
          path: "/tv/Mixed Res Show/Season 01/Mixed.Res.Show.S01E03.4k.mkv",
          height: 2160,
          width: 3840,
          state: :crf_searched
        })

      add_chosen_vmafs([video_4k], [10.0])

      # Target is 1080p - should only find 1080p siblings
      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Mixed Res Show/Season 01/Mixed.Res.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      crfs = CrfSearchHints.sibling_crfs(target)
      assert length(crfs) == 2
      assert 10.0 not in crfs
    end

    test "filters out siblings with different HDR status" do
      # Create SDR siblings with VMAFs
      videos_sdr =
        create_season_siblings("HDR Mix Show", 1, 2, %{height: 1080, width: 1920, hdr: nil})

      add_chosen_vmafs(videos_sdr, [25.0, 28.0])

      # Create HDR sibling with VMAF
      {:ok, video_hdr} =
        Fixtures.video_fixture(%{
          path: "/tv/HDR Mix Show/Season 01/HDR.Mix.Show.S01E03.HDR.mkv",
          height: 1080,
          width: 1920,
          hdr: "HDR10",
          state: :crf_searched
        })

      add_chosen_vmafs([video_hdr], [12.0])

      # Target is SDR - should only find SDR siblings
      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/HDR Mix Show/Season 01/HDR.Mix.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          hdr: nil,
          state: :analyzed
        })

      crfs = CrfSearchHints.sibling_crfs(target)
      assert length(crfs) == 2
      assert 12.0 not in crfs
    end

    test "ignores videos without chosen VMAF" do
      # Create siblings - some with chosen VMAFs, some without
      videos = create_season_siblings("Partial VMAF Show", 1, 3, %{height: 1080, width: 1920})

      # Only first 2 get chosen VMAFs
      [v1, v2, _v3] = videos
      add_chosen_vmafs([v1, v2], [20.0, 22.0])
      # v3 has no VMAF at all

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Partial VMAF Show/Season 01/Partial.VMAF.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      crfs = CrfSearchHints.sibling_crfs(target)
      assert length(crfs) == 2
    end

    test "excludes the target video itself from siblings" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Self Show/Season 01/Self.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      add_chosen_vmafs([video], [20.0])

      crfs = CrfSearchHints.sibling_crfs(video)
      assert crfs == []
    end

    test "returns empty for videos with no season folder in path" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/movies/No Season/movie.mkv",
          state: :analyzed
        })

      assert CrfSearchHints.sibling_crfs(video) == []
    end

    test "works with different season folder formats" do
      # Create sibling in "Season 01" format
      {:ok, sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Format Show/Season 01/Format.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      add_chosen_vmafs([sibling], [22.0])

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Format Show/Season 01/Format.Show.S01E02.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      crfs = CrfSearchHints.sibling_crfs(target)
      assert crfs == [22.0]
    end

    test "does not cross season boundaries" do
      # Create sibling in Season 01
      {:ok, s1_sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Boundary Show/Season 01/Boundary.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      add_chosen_vmafs([s1_sibling], [20.0])

      # Target is in Season 02
      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Boundary Show/Season 02/Boundary.Show.S02E01.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      crfs = CrfSearchHints.sibling_crfs(target)
      assert crfs == []
    end
  end

  describe "narrowed_range?/1" do
    test "returns true for ranges narrower than default" do
      assert CrfSearchHints.narrowed_range?({14, 30})
      assert CrfSearchHints.narrowed_range?({10, 35})
    end

    test "returns false for default range" do
      refute CrfSearchHints.narrowed_range?({8, 40})
    end

    test "returns false for wider-than-default range" do
      refute CrfSearchHints.narrowed_range?({5, 55})
    end
  end

  # Helper functions

  defp create_season_siblings(show_name, season, count, attrs) do
    season_str = String.pad_leading(to_string(season), 2, "0")

    Enum.map(1..count, fn ep ->
      ep_str = String.pad_leading(to_string(ep), 2, "0")

      {:ok, video} =
        Fixtures.video_fixture(
          Map.merge(
            %{
              path:
                "/tv/#{show_name}/Season #{season_str}/#{show_name}.S#{season_str}E#{ep_str}.mkv",
              state: :crf_searched
            },
            attrs
          )
        )

      video
    end)
  end

  defp add_chosen_vmafs(videos, crfs) do
    Enum.zip(videos, crfs)
    |> Enum.each(fn {video, crf} ->
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: crf,
          score: 95.0,
          chosen: true,
          params: ["--preset", "4"]
        })
    end)
  end
end
