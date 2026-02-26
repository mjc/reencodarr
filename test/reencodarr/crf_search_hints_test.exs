defmodule Reencodarr.CrfSearchHintsTest do
  @moduledoc """
  Tests for CrfSearchHints — score-based CRF bracketing.

  Priority: own VMAF records (margin ±2) → sibling chosen records (margin ±4) → default {5, 70}.
  On retry, sibling narrowing is skipped; own records still used if present.

  ## Bracketing logic under test

  - Passing (score ≥ target): highest-CRF passing record → floor (that CRF − margin)
  - Failing (score < target): lowest-CRF failing record → ceiling (that CRF + margin)
  - Only passing: ceiling = highest_passing_crf + margin * 2
  - Only failing: floor = absolute_min (5)
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.CrfSearchHints
  alias Reencodarr.Media

  @target 94
  @default_range {5, 70}

  describe "crf_range/3" do
    test "returns default range when no own records or siblings" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Alone Show/Season 01/Alone.Show.S01E01.mkv",
          state: :analyzed
        })

      assert CrfSearchHints.crf_range(video, @target) == @default_range
    end

    test "brackets using own failing records — Westworld scenario" do
      # CRF 8 scored 93.65, CRF 24 scored 89.60 — both below target 94
      {:ok, video} =
        Fixtures.video_fixture(%{path: "/movies/Test (2024)/Test.mkv", state: :analyzed})

      add_vmaf_records(video, [{8.0, 93.65, false}, {24.0, 89.60, false}])

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target)

      # Both failing → floor = absolute_min = 5
      #               ceiling = lowest_failing(8) + margin(2) = 10
      assert min_crf == 5
      assert max_crf == 10
    end

    test "brackets using own mixed records — passing and failing" do
      # CRF 20 just passes (95.0 ≥ 94), CRF 25 fails (92.0 < 94)
      {:ok, video} =
        Fixtures.video_fixture(%{path: "/movies/Mixed (2024)/Mixed.mkv", state: :analyzed})

      add_vmaf_records(video, [{20.0, 95.0, false}, {25.0, 92.0, false}])

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target)

      # floor = highest_passing(20) − margin(2) = 18
      # ceiling = lowest_failing(25) + margin(2) = 27
      assert min_crf == 18
      assert max_crf == 27
    end

    test "brackets using own passing-only records" do
      # Both records pass — ceiling is above highest passing CRF
      {:ok, video} =
        Fixtures.video_fixture(%{path: "/movies/Pass (2024)/Pass.mkv", state: :analyzed})

      add_vmaf_records(video, [{18.0, 96.0, true}, {22.0, 94.5, false}])

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target)

      # floor = highest_passing(22) − 2 = 20
      # no failing → ceiling = highest_passing(22) + margin*2(4) = 26
      assert min_crf == 20
      assert max_crf == 26
    end

    test "own records take priority over siblings" do
      siblings = create_season_siblings("Priority Show", 1, 2, %{height: 1080, width: 1920})
      add_vmaf_records_chosen(siblings, [{20.0, 95.5}, {22.0, 94.2}])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Priority Show/Season 01/Priority.Show.S01E03.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      # Own record: CRF 8, score 93.65 — failing
      add_vmaf_records(video, [{8.0, 93.65, false}])

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target)

      # Own data used, not siblings → floor=5, ceiling=8+2=10
      assert min_crf == 5
      assert max_crf == 10
    end

    test "falls back to sibling records when no own records" do
      # Siblings: CRF 20 (95.5 passing), CRF 24 (94.1 passing)
      siblings = create_season_siblings("Sibling Show", 1, 2, %{height: 1080, width: 1920})
      add_vmaf_records_chosen(siblings, [{20.0, 95.5}, {24.0, 94.1}])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Sibling Show/Season 01/Sibling.Show.S01E03.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target)

      # Both siblings passing; highest_passing=24, margin=4
      # floor = 24 − 4 = 20, no failing → ceiling = 24 + 4*2 = 32
      assert min_crf == 20
      assert max_crf == 32
    end

    test "sibling with failing score acts as ceiling" do
      # Sibling chose CRF 20 but its score is below our target (different target was used)
      {:ok, sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Low Score Show/Season 01/Low.Score.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      Media.create_vmaf(%{
        video_id: sibling.id,
        crf: 20.0,
        score: 92.0,
        chosen: true,
        params: ["--preset", "4"]
      })

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Low Score Show/Season 01/Low.Score.Show.S01E02.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target)

      # Sibling failing at target 94 → floor=5, ceiling=20+4=24
      assert min_crf == 5
      assert max_crf == 24
    end

    test "on retry, returns default range when no own records" do
      siblings = create_season_siblings("Retry Show", 1, 2, %{height: 1080, width: 1920})
      add_vmaf_records_chosen(siblings, [{20.0, 95.0}, {22.0, 94.5}])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Retry Show/Season 01/Retry.Show.S01E03.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      assert CrfSearchHints.crf_range(video, @target, retry: true) == @default_range
    end

    test "on retry, uses own records and skips siblings" do
      siblings = create_season_siblings("Retry Own Show", 1, 2, %{height: 1080, width: 1920})
      add_vmaf_records_chosen(siblings, [{20.0, 95.0}, {22.0, 94.5}])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Retry Own Show/Season 01/Retry.Own.Show.S01E03.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      add_vmaf_records(video, [{8.0, 93.7, false}])

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target, retry: true)

      # Own record CRF 8 failing → floor=5, ceiling=8+2=10
      assert min_crf == 5
      assert max_crf == 10
    end

    test "result is clamped to absolute bounds" do
      siblings = create_season_siblings("Low CRF Show", 1, 2, %{height: 2160, width: 3840})
      add_vmaf_records_chosen(siblings, [{6.0, 94.5}, {7.0, 94.1}])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Low CRF Show/Season 01/Low.CRF.Show.S01E03.mkv",
          height: 2160,
          width: 3840,
          state: :analyzed
        })

      {min_crf, max_crf} = CrfSearchHints.crf_range(video, @target)
      assert min_crf >= 5
      assert max_crf <= 70
    end

    test "returns default range for movies (no season folder)" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/movies/Some Movie (2024)/Some.Movie.2024.mkv",
          state: :analyzed
        })

      assert CrfSearchHints.crf_range(video, @target) == @default_range
    end
  end

  describe "own_vmaf_records/1" do
    test "returns {crf, score} pairs including unchosen records" do
      {:ok, video} =
        Fixtures.video_fixture(%{path: "/movies/Test (2024)/Test.mkv", state: :analyzed})

      add_vmaf_records(video, [{8.0, 93.65, false}, {20.0, 95.0, true}, {24.0, 89.60, false}])

      records = CrfSearchHints.own_vmaf_records(video)
      assert length(records) == 3
      crfs = Enum.map(records, &elem(&1, 0)) |> Enum.sort()
      assert crfs == [8.0, 20.0, 24.0]
    end

    test "returns empty list when video has no VMAF records" do
      {:ok, video} =
        Fixtures.video_fixture(%{path: "/movies/Fresh (2024)/Fresh.mkv", state: :analyzed})

      assert CrfSearchHints.own_vmaf_records(video) == []
    end

    test "does not include other videos' records" do
      {:ok, v1} =
        Fixtures.video_fixture(%{path: "/movies/One (2024)/One.mkv", state: :analyzed})

      {:ok, v2} =
        Fixtures.video_fixture(%{path: "/movies/Two (2024)/Two.mkv", state: :analyzed})

      add_vmaf_records(v1, [{20.0, 95.0, true}])
      add_vmaf_records(v2, [{30.0, 94.2, true}])

      assert CrfSearchHints.own_vmaf_records(v1) == [{20.0, 95.0}]
      assert CrfSearchHints.own_vmaf_records(v2) == [{30.0, 94.2}]
    end
  end

  describe "sibling_vmaf_records/1" do
    test "returns {crf, score} pairs from chosen sibling records" do
      siblings = create_season_siblings("Test Show", 1, 3, %{height: 1080, width: 1920})
      add_vmaf_records_chosen(siblings, [{18.0, 96.0}, {22.0, 95.0}, {25.0, 94.1}])

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Test Show/Season 01/Test.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      records = CrfSearchHints.sibling_vmaf_records(target)
      assert length(records) == 3
      crfs = Enum.map(records, &elem(&1, 0)) |> Enum.sort()
      assert crfs == [18.0, 22.0, 25.0]
    end

    test "filters out siblings with different resolution" do
      videos_1080 = create_season_siblings("Res Show", 1, 2, %{height: 1080, width: 1920})
      add_vmaf_records_chosen(videos_1080, [{20.0, 95.0}, {22.0, 94.5}])

      {:ok, video_4k} =
        Fixtures.video_fixture(%{
          path: "/tv/Res Show/Season 01/Res.Show.S01E03.4k.mkv",
          height: 2160,
          width: 3840,
          state: :crf_searched
        })

      add_vmaf_records_chosen([video_4k], [{10.0, 94.8}])

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Res Show/Season 01/Res.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      records = CrfSearchHints.sibling_vmaf_records(target)
      assert length(records) == 2
      refute Enum.any?(records, fn {crf, _} -> crf == 10.0 end)
    end

    test "filters out siblings with different HDR status" do
      videos_sdr =
        create_season_siblings("HDR Show", 1, 2, %{height: 1080, width: 1920, hdr: nil})

      add_vmaf_records_chosen(videos_sdr, [{25.0, 95.0}, {28.0, 94.3}])

      {:ok, video_hdr} =
        Fixtures.video_fixture(%{
          path: "/tv/HDR Show/Season 01/HDR.Show.S01E03.HDR.mkv",
          height: 1080,
          width: 1920,
          hdr: "HDR10",
          state: :crf_searched
        })

      add_vmaf_records_chosen([video_hdr], [{12.0, 94.5}])

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/HDR Show/Season 01/HDR.Show.S01E04.mkv",
          height: 1080,
          width: 1920,
          hdr: nil,
          state: :analyzed
        })

      records = CrfSearchHints.sibling_vmaf_records(target)
      assert length(records) == 2
      refute Enum.any?(records, fn {crf, _} -> crf == 12.0 end)
    end

    test "excludes the target video itself" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Self Show/Season 01/Self.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      add_vmaf_records_chosen([video], [{20.0, 95.0}])

      assert CrfSearchHints.sibling_vmaf_records(video) == []
    end

    test "returns empty for movies (no season folder)" do
      {:ok, video} =
        Fixtures.video_fixture(%{path: "/movies/No Season/movie.mkv", state: :analyzed})

      assert CrfSearchHints.sibling_vmaf_records(video) == []
    end

    test "does not cross season boundaries" do
      {:ok, s1_sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Boundary Show/Season 01/Boundary.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      add_vmaf_records_chosen([s1_sibling], [{20.0, 95.0}])

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Boundary Show/Season 02/Boundary.Show.S02E01.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      assert CrfSearchHints.sibling_vmaf_records(target) == []
    end

    test "only returns chosen records, not unchosen probes" do
      {:ok, sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Chosen Show/Season 01/Chosen.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      Media.create_vmaf(%{
        video_id: sibling.id,
        crf: 20.0,
        score: 95.0,
        chosen: true,
        params: ["--preset", "4"]
      })

      Media.create_vmaf(%{
        video_id: sibling.id,
        crf: 30.0,
        score: 91.0,
        chosen: false,
        params: ["--preset", "4"]
      })

      {:ok, target} =
        Fixtures.video_fixture(%{
          path: "/tv/Chosen Show/Season 01/Chosen.Show.S01E02.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      records = CrfSearchHints.sibling_vmaf_records(target)
      assert records == [{20.0, 95.0}]
    end
  end

  describe "narrowed_range?/1" do
    test "returns true for ranges narrower than default" do
      assert CrfSearchHints.narrowed_range?({14, 30})
      assert CrfSearchHints.narrowed_range?({10, 35})
      assert CrfSearchHints.narrowed_range?({8, 40})
    end

    test "returns false for default range" do
      refute CrfSearchHints.narrowed_range?({5, 70})
    end

    test "returns true if only one side is narrowed" do
      assert CrfSearchHints.narrowed_range?({5, 50})
      assert CrfSearchHints.narrowed_range?({10, 70})
    end
  end

  # Helpers

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

  # Add [{crf, score, chosen}] records to a single video
  defp add_vmaf_records(video, records) do
    Enum.each(records, fn {crf, score, chosen} ->
      {:ok, _} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: crf,
          score: score,
          chosen: chosen,
          params: ["--preset", "4"]
        })
    end)
  end

  # Add [{crf, score}] chosen records to a list of videos (one per video)
  defp add_vmaf_records_chosen(videos, crf_scores) do
    Enum.zip(videos, crf_scores)
    |> Enum.each(fn {video, {crf, score}} ->
      {:ok, _} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: crf,
          score: score,
          chosen: true,
          params: ["--preset", "4"]
        })
    end)
  end
end
