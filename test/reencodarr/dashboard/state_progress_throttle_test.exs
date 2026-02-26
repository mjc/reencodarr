defmodule Reencodarr.Dashboard.StateProgressThrottleTest do
  @moduledoc """
  Tests that Dashboard.State debounces crf_search_progress events.
  """
  use Reencodarr.DataCase, async: false

  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Dashboard.State

  @state_channel "dashboard:state"

  setup do
    # Start Dashboard.State if not already running
    case GenServer.whereis(State) do
      nil ->
        {:ok, _pid} = State.start_link()
        :ok

      _pid ->
        :ok
    end

    Phoenix.PubSub.subscribe(Reencodarr.PubSub, @state_channel)
    :ok
  end

  describe "progress debounce" do
    test "first progress event is broadcast immediately" do
      Events.broadcast_event(:crf_search_progress, %{
        video_id: 1,
        percent: 10,
        filename: "test.mkv"
      })

      assert_receive {:dashboard_state_changed, state}, 200
      assert state.crf_progress.percent == 10
    end

    test "rapid progress events are debounced" do
      # Send many rapid progress events
      for percent <- 1..20 do
        Events.broadcast_event(:crf_search_progress, %{
          video_id: 1,
          percent: percent,
          filename: "test.mkv"
        })
      end

      # We should receive at most a few state broadcasts, not 20
      # Drain all messages within 700ms
      Process.sleep(700)
      messages = drain_messages()
      count = Enum.count(messages)

      # Should have far fewer broadcasts than the 20 raw events
      assert count < 20,
             "Expected debounced broadcasts but got #{count}"

      # The final state should reflect the last progress value
      if messages != [] do
        last_state = List.last(messages)
        assert last_state.crf_progress.percent == 20
      end
    end
  end

  defp drain_messages(acc \\ []) do
    receive do
      {:dashboard_state_changed, state} -> drain_messages([state | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
