defmodule Reencodarr.AbAv1.CrfSearchTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf

  describe "process_line/2" do
    setup do
      video = %{id: 1, path: "test_path", size: 100}
      {:ok, video} = Media.create_video(video)
      {:ok, video: video}
    end

    test "parses valid line and returns VMAF", %{video: video} do
      line =
        "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] sample 1/5 crf 28 VMAF 91.33 (4%)"

      vmaf = CrfSearch.process_line(line, video)
      video_id = video.id

      assert %Reencodarr.Media.Vmaf{
               video_id: ^video_id,
               crf: 28.0,
               chosen: false,
               score: 91.33,
               percent: 95.0,
               params: ["example_param=example_value"]
             } = vmaf
    end

    test "ignores invalid line and returns :none", %{video: video} do
      line =
        "[2024-12-12T00:13:08Z INFO  ab_av1::command::sample_encode] encoding sample 1/5 crf 28"

      vmaf = CrfSearch.process_line(line, video)

      assert vmaf == :none
    end

    test "parses multiple lines from fixture file", %{video: video} do
      File.read!("test/fixtures/crf-search-output.txt")
      |> String.split("\n")
      |> Enum.each(fn line ->
        vmaf = CrfSearch.process_line(line, video)

        if line =~ ~r/crf \d+(\.\d+)? VMAF \d+\.\d+ \(\d+%\)/ do
          assert %Vmaf{} = vmaf
        else
          assert vmaf == :none
        end
      end)
    end
  end
end
