defmodule Reencodarr.Dashboard.EventsTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Dashboard.Events

  describe "channel/0" do
    test "returns a string channel name" do
      assert is_binary(Events.channel())
    end

    test "returns the dashboard channel name" do
      assert Events.channel() == "dashboard"
    end
  end

  describe "broadcast_event/2" do
    setup do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      :ok
    end

    test "broadcasts event to dashboard channel with empty data default" do
      Events.broadcast_event(:test_event)

      assert_receive {:test_event, %{}}
    end

    test "broadcasts event with provided data map" do
      Events.broadcast_event(:test_event, %{video_id: 42})

      assert_receive {:test_event, %{video_id: 42}}
    end

    test "broadcasts event with atom name" do
      Events.broadcast_event(:some_action, %{key: "value"})

      assert_receive {:some_action, %{key: "value"}}
    end
  end

  describe "pipeline_state_changed/3" do
    setup do
      Enum.each([:analyzer, :crf_searcher, :encoder], fn service ->
        Phoenix.PubSub.subscribe(Reencodarr.PubSub, Atom.to_string(service))
      end)

      :ok
    end

    test "returns {:ok, to_state} for analyzer" do
      assert {:ok, :running} = Events.pipeline_state_changed(:analyzer, :idle, :running)
    end

    test "returns {:ok, to_state} for crf_searcher" do
      assert {:ok, :paused} = Events.pipeline_state_changed(:crf_searcher, :running, :paused)
    end

    test "returns {:ok, to_state} for encoder" do
      assert {:ok, :idle} = Events.pipeline_state_changed(:encoder, :running, :idle)
    end

    test "broadcasts state change on the service channel for analyzer" do
      Events.pipeline_state_changed(:analyzer, :idle, :processing)

      assert_receive {:analyzer, :processing}
    end

    test "broadcasts state change on the service channel for crf_searcher" do
      Events.pipeline_state_changed(:crf_searcher, :idle, :running)

      assert_receive {:crf_searcher, :running}
    end

    test "broadcasts state change on the service channel for encoder" do
      Events.pipeline_state_changed(:encoder, :idle, :stopped)

      assert_receive {:encoder, :stopped}
    end

    test "returned to_state matches the broadcast state" do
      {:ok, returned_state} = Events.pipeline_state_changed(:analyzer, :idle, :pausing)

      assert_receive {:analyzer, received_state}
      assert returned_state == received_state
    end
  end
end
