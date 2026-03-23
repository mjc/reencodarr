defmodule Reencodarr.Videos.StateTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Fixtures
  alias Reencodarr.Videos.State

  test "load/1 returns the videos page payload" do
    {:ok, _video} =
      Fixtures.video_fixture(%{path: "/media/videos_state_payload.mkv", state: :encoded})

    payload =
      State.load(%{
        page: 1,
        per_page: 50,
        state_filter: nil,
        service_filter: nil,
        hdr_filter: nil,
        search: "",
        sort_by: :updated_at,
        sort_dir: :desc
      })

    assert Enum.any?(payload.videos, &(&1.path == "/media/videos_state_payload.mkv"))
    assert payload.total >= 1
    assert is_map(payload.state_counts)
    assert payload.page == 1
    assert payload.per_page == 50
  end
end
