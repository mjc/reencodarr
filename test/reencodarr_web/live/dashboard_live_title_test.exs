defmodule ReencodarrWeb.DashboardLiveTitleTest do
  use ExUnit.Case, async: true

  alias ReencodarrWeb.DashboardLive

  describe "dashboard_page_title/1" do
    test "renders crf search progress only" do
      state = %{
        crf_search_sample: %{sample_num: 2, total_samples: 10},
        encoding_progress: :none,
        service_status: %{crf_searcher: :processing, encoder: :idle}
      }

      assert DashboardLive.dashboard_page_title(state) == "2/10"
    end

    test "renders encode progress only" do
      state = %{
        crf_search_sample: nil,
        encoding_progress: %{percent: 42.0, fps: 30.5},
        service_status: %{crf_searcher: :idle, encoder: :processing}
      }

      assert DashboardLive.dashboard_page_title(state) == "30.5fps 42%"
    end

    test "renders combined crf search and encode progress" do
      state = %{
        crf_search_sample: %{sample_num: 1, total_samples: 8},
        encoding_progress: %{percent: 67.2, fps: 29.97},
        service_status: %{crf_searcher: :processing, encoder: :processing}
      }

      assert DashboardLive.dashboard_page_title(state) == "1/8 30fps 67.2%"
    end

    test "omits paused crf search from the title while encoding is active" do
      state = %{
        crf_search_sample: %{sample_num: 4, total_samples: 12},
        encoding_progress: %{percent: 12.0, fps: 24.0},
        service_status: %{crf_searcher: :paused, encoder: :processing}
      }

      assert DashboardLive.dashboard_page_title(state) == "24fps 12%"
    end

    test "renders nil when all services are paused or idle" do
      state = %{
        crf_search_sample: %{sample_num: 4, total_samples: 12},
        encoding_progress: %{percent: 12.0, fps: 24.0},
        service_status: %{crf_searcher: :paused, encoder: :paused}
      }

      assert DashboardLive.dashboard_page_title(state) == nil
    end

    test "renders nil when nothing active" do
      state = %{
        crf_search_sample: nil,
        encoding_progress: :none,
        service_status: %{crf_searcher: :idle, encoder: :idle}
      }

      assert DashboardLive.dashboard_page_title(state) == nil
    end
  end
end
