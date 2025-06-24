defmodule Reencodarr.AbAv1.CrfSearchTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf

  describe "process_line/3 (direct call)" do
    setup do
      video = %{id: 1, path: "test_path", size: 100}
      {:ok, video} = Media.create_video(video)
      %{video: video}
    end

    test "creates VMAF record for valid line", %{video: video} do
      line = "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf 28 VMAF 91.33 (4%)"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
      apply(Reencodarr.AbAv1.CrfSearch, :process_line, [line, video, []])
      assert Repo.aggregate(Vmaf, :count, :id) == 1
      vmaf = Repo.one(Vmaf)
      assert vmaf.video_id == video.id
      assert vmaf.crf == 28.0
      assert vmaf.score == 91.33
    end

    test "does not create VMAF record for invalid line", %{video: video} do
      line = "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] encoding sample 1/5 crf 28"
      assert Repo.aggregate(Vmaf, :count, :id) == 0
      apply(Reencodarr.AbAv1.CrfSearch, :process_line, [line, video, []])
      assert Repo.aggregate(Vmaf, :count, :id) == 0
    end

    test "parses multiple lines from fixture file and creates VMAF records for valid lines", %{video: video} do
      lines =
        File.read!("test/fixtures/crf-search-output.txt")
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      assert Repo.aggregate(Vmaf, :count, :id) == 0
      Enum.each(lines, fn line ->
        apply(Reencodarr.AbAv1.CrfSearch, :process_line, [line, video, []])
      end)
      vmaf_lines = Enum.filter(lines, &(&1 =~ ~r/crf \d+(\.\d+)? VMAF \d+\.\d+ \(\d+%\)/))
      assert Repo.aggregate(Vmaf, :count, :id) == length(vmaf_lines)
    end
  end
end
