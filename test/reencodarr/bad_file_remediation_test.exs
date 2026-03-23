defmodule Reencodarr.BadFileRemediationTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.BadFileRemediation
  alias Reencodarr.Media

  setup do
    :meck.unload()
    :ok
  end

  test "process_next_issue/1 returns :idle when no issue is queued" do
    assert :idle = BadFileRemediation.process_next_issue()
  end

  test "process_next_issue/1 moves a Sonarr issue into waiting_for_replacement after delete/search" do
    {:ok, video} =
      Fixtures.video_fixture(%{
        path: "/media/sonarr-bad.mkv",
        service_type: :sonarr,
        service_id: "55"
      })

    {:ok, issue} =
      Media.create_bad_file_issue(video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "bad replacement"
      })

    {:ok, queued_issue} = Media.enqueue_bad_file_issue(issue)

    :meck.new(Reencodarr.Services.Sonarr, [:passthrough])

    :meck.expect(Reencodarr.Services.Sonarr, :get_episode_file, fn 55 ->
      {:ok, %{body: %{"id" => 55}}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :get_episodes_by_file, fn 55 ->
      {:ok, %{body: [%{"id" => 101}, %{"id" => 102}]}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :set_episodes_monitored, fn [101, 102], true ->
      {:ok, %{body: %{"updated" => true}}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :delete_episode_file, fn 55 ->
      {:ok, %{status: 200}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :trigger_episode_search, fn [101, 102] ->
      {:ok, %{body: %{"id" => 999}}}
    end)

    assert {:ok, updated_issue} = BadFileRemediation.process_next_issue()
    assert updated_issue.id == queued_issue.id
    assert updated_issue.status == :waiting_for_replacement
  end

  test "process_next_issue/1 moves a Radarr issue into waiting_for_replacement after delete/search" do
    {:ok, video} =
      Fixtures.video_fixture(%{
        path: "/media/radarr-bad.mkv",
        service_type: :radarr,
        service_id: "88"
      })

    {:ok, issue} =
      Media.create_bad_file_issue(video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "wrong cut"
      })

    Media.enqueue_bad_file_issue(issue)

    :meck.new(Reencodarr.Services.Radarr, [:passthrough])

    :meck.expect(Reencodarr.Services.Radarr, :get_movie_file, fn 88 ->
      {:ok, %{body: %{"movieId" => 77}}}
    end)

    :meck.expect(Reencodarr.Services.Radarr, :set_movie_monitored, fn 77, true ->
      {:ok, %{body: %{"updated" => true}}}
    end)

    :meck.expect(Reencodarr.Services.Radarr, :delete_movie_file, fn 88 ->
      {:ok, %{status: 200}}
    end)

    :meck.expect(Reencodarr.Services.Radarr, :trigger_movie_search, fn 77 ->
      {:ok, %{body: %{"id" => 444}}}
    end)

    assert {:ok, updated_issue} = BadFileRemediation.process_next_issue()
    assert updated_issue.status == :waiting_for_replacement
  end

  test "process_next_issue/1 can process the next queued issue for a specific service" do
    {:ok, sonarr_video} =
      Fixtures.video_fixture(%{
        path: "/media/service-filter-sonarr.mkv",
        service_type: :sonarr,
        service_id: "155"
      })

    {:ok, radarr_video} =
      Fixtures.video_fixture(%{
        path: "/media/service-filter-radarr.mkv",
        service_type: :radarr,
        service_id: "288"
      })

    {:ok, sonarr_issue} =
      Media.create_bad_file_issue(sonarr_video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "tv issue"
      })

    {:ok, radarr_issue} =
      Media.create_bad_file_issue(radarr_video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "movie issue"
      })

    {:ok, _queued_sonarr_issue} = Media.enqueue_bad_file_issue(sonarr_issue)
    {:ok, _queued_radarr_issue} = Media.enqueue_bad_file_issue(radarr_issue)

    :meck.new(Reencodarr.Services.Sonarr, [:passthrough])

    :meck.expect(Reencodarr.Services.Sonarr, :get_episode_file, fn 155 ->
      {:ok, %{body: %{"id" => 155}}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :get_episodes_by_file, fn 155 ->
      {:ok, %{body: [%{"id" => 201}]}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :set_episodes_monitored, fn [201], true ->
      {:ok, %{body: %{"updated" => true}}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :delete_episode_file, fn 155 ->
      {:ok, %{status: 200}}
    end)

    :meck.expect(Reencodarr.Services.Sonarr, :trigger_episode_search, fn [201] ->
      {:ok, %{body: %{"id" => 1001}}}
    end)

    assert {:ok, updated_issue} = BadFileRemediation.process_next_issue(service_type: :sonarr)
    assert updated_issue.id == sonarr_issue.id
    assert updated_issue.status == :waiting_for_replacement
    assert Media.get_bad_file_issue!(radarr_issue.id).status == :queued
  end

  test "process_next_issue/1 resolves already-fixed issues without delete/search" do
    {:ok, video} =
      Fixtures.video_fixture(%{
        path: "/media/already-fixed.mkv",
        service_type: :sonarr,
        service_id: "55"
      })

    {:ok, issue} =
      Media.create_bad_file_issue(video, %{
        origin: :audit,
        issue_kind: :audio,
        classification: :likely_bad_pre_commit_multichannel_opus
      })

    Media.enqueue_bad_file_issue(issue)

    assert {:ok, resolved_issue} =
             BadFileRemediation.process_next_issue(
               already_fixed_fun: fn queued_video, queued_issue ->
                 queued_video.id == video.id and queued_issue.id == issue.id
               end
             )

    assert resolved_issue.status == :replaced_clean
  end
end
