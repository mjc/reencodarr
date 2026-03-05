defmodule Reencodarr.Media.VideoFailureTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.VideoFailure

  defp valid_attrs do
    %{
      video_id: 1,
      failure_stage: :analysis,
      failure_category: :file_access,
      failure_message: "File not found: /media/show.mkv"
    }
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = VideoFailure.changeset(%VideoFailure{}, valid_attrs())
      assert cs.valid?
    end

    test "missing video_id makes changeset invalid" do
      cs = VideoFailure.changeset(%VideoFailure{}, Map.delete(valid_attrs(), :video_id))
      refute cs.valid?
    end

    test "missing failure_stage makes changeset invalid" do
      cs = VideoFailure.changeset(%VideoFailure{}, Map.delete(valid_attrs(), :failure_stage))
      refute cs.valid?
    end

    test "missing failure_category makes changeset invalid" do
      cs =
        VideoFailure.changeset(%VideoFailure{}, Map.delete(valid_attrs(), :failure_category))

      refute cs.valid?
    end

    test "missing failure_message makes changeset invalid" do
      cs =
        VideoFailure.changeset(%VideoFailure{}, Map.delete(valid_attrs(), :failure_message))

      refute cs.valid?
    end

    test "invalid failure_stage makes changeset invalid" do
      cs =
        VideoFailure.changeset(
          %VideoFailure{},
          Map.put(valid_attrs(), :failure_stage, :unknown_stage)
        )

      refute cs.valid?
    end

    test "invalid failure_category makes changeset invalid" do
      cs =
        VideoFailure.changeset(
          %VideoFailure{},
          Map.put(valid_attrs(), :failure_category, :bad_category)
        )

      refute cs.valid?
    end

    test "negative retry_count makes changeset invalid" do
      cs =
        VideoFailure.changeset(%VideoFailure{}, Map.put(valid_attrs(), :retry_count, -1))

      refute cs.valid?
    end

    test "retry_count of 0 is valid" do
      cs = VideoFailure.changeset(%VideoFailure{}, Map.put(valid_attrs(), :retry_count, 0))
      assert cs.valid?
    end

    test "retry_count > 0 is valid" do
      cs = VideoFailure.changeset(%VideoFailure{}, Map.put(valid_attrs(), :retry_count, 5))
      assert cs.valid?
    end

    test "defaults resolved to false" do
      cs = VideoFailure.changeset(%VideoFailure{}, valid_attrs())
      assert Ecto.Changeset.get_field(cs, :resolved) == false
    end

    test "system_context can be a map" do
      attrs =
        Map.put(valid_attrs(), :system_context, %{
          "command" => "mediainfo /path/to/file",
          "exit_code" => 1
        })

      cs = VideoFailure.changeset(%VideoFailure{}, attrs)
      assert cs.valid?
    end

    test "all valid failure_stages are accepted" do
      for stage <- [:analysis, :crf_search, :encoding, :post_process] do
        cs =
          VideoFailure.changeset(%VideoFailure{}, Map.put(valid_attrs(), :failure_stage, stage))

        assert cs.valid?, "Expected stage #{stage} to be valid"
      end
    end

    test "all valid failure_categories are accepted" do
      valid_categories = [
        :file_access,
        :mediainfo_parsing,
        :validation,
        :vmaf_calculation,
        :crf_optimization,
        :size_limits,
        :preset_retry,
        :process_failure,
        :resource_exhaustion,
        :codec_issues,
        :timeout,
        :file_operations,
        :sync_integration,
        :cleanup,
        :configuration,
        :system_environment,
        :unknown
      ]

      for category <- valid_categories do
        cs =
          VideoFailure.changeset(
            %VideoFailure{},
            Map.put(valid_attrs(), :failure_category, category)
          )

        assert cs.valid?, "Expected category #{category} to be valid"
      end
    end

    test "failure_code is optional" do
      attrs = Map.put(valid_attrs(), :failure_code, "ENOENT")
      cs = VideoFailure.changeset(%VideoFailure{}, attrs)
      assert cs.valid?
    end
  end

  describe "failure_stages/0" do
    test "returns list of valid failure stages" do
      stages = VideoFailure.failure_stages()
      assert is_list(stages)
      assert :analysis in stages
      assert :encoding in stages
    end
  end

  describe "failure_categories/0" do
    test "returns list of valid failure categories" do
      categories = VideoFailure.failure_categories()
      assert is_list(categories)
      assert :file_access in categories
      assert :unknown in categories
    end
  end
end
