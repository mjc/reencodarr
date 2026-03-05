defmodule Reencodarr.ErrorHelpersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Reencodarr.ErrorHelpers

  describe "log_and_return_error/2" do
    test "returns error tuple with the given reason" do
      assert {:error, :connection_failed} =
               ErrorHelpers.log_and_return_error(:connection_failed)
    end

    test "returns error tuple with any reason type" do
      assert {:error, "some string"} = ErrorHelpers.log_and_return_error("some string")
      assert {:error, {:nested, :reason}} = ErrorHelpers.log_and_return_error({:nested, :reason})
    end

    test "logs with context when provided" do
      log =
        capture_log(fn ->
          ErrorHelpers.log_and_return_error(:timeout, "API request")
        end)

      assert log =~ "API request"
    end

    test "logs without context prefix when context is empty" do
      log =
        capture_log(fn ->
          ErrorHelpers.log_and_return_error(:oops)
        end)

      assert log =~ "oops"
    end
  end

  describe "config_not_found_error/1" do
    test "returns config_not_found error tuple" do
      assert {:error, :config_not_found} = ErrorHelpers.config_not_found_error("Sonarr")
    end

    test "logs with service name" do
      log =
        capture_log(fn ->
          ErrorHelpers.config_not_found_error("Radarr")
        end)

      assert log =~ "Radarr"
    end
  end

  describe "handle_nil_value/3" do
    test "returns ok tuple when value is not nil" do
      assert {:ok, 42} = ErrorHelpers.handle_nil_value(42, "SomeField")
      assert {:ok, "hello"} = ErrorHelpers.handle_nil_value("hello", "Name")
      assert {:ok, []} = ErrorHelpers.handle_nil_value([], "List")
    end

    test "returns nil_value error when value is nil" do
      assert {:error, {:nil_value, "Movie ID"}} = ErrorHelpers.handle_nil_value(nil, "Movie ID")
    end

    test "includes context in error message log" do
      log =
        capture_log(fn ->
          ErrorHelpers.handle_nil_value(nil, "Episode ID", "Cannot rename files")
        end)

      assert log =~ "Cannot rename files"
      assert log =~ "Episode ID"
    end

    test "logs without context when context is empty" do
      log =
        capture_log(fn ->
          ErrorHelpers.handle_nil_value(nil, "Series ID")
        end)

      assert log =~ "Series ID"
    end
  end

  describe "handle_error_with_default/3" do
    test "returns value from ok tuple" do
      assert ErrorHelpers.handle_error_with_default({:ok, "result"}, "fallback") == "result"
    end

    test "returns default on error tuple" do
      assert ErrorHelpers.handle_error_with_default({:error, :timeout}, "fallback") == "fallback"
    end

    test "returns default on unexpected result" do
      assert ErrorHelpers.handle_error_with_default(:unexpected, "fallback") == "fallback"
    end

    test "logs error with context when provided" do
      log =
        capture_log(fn ->
          ErrorHelpers.handle_error_with_default({:error, :timeout}, "default", "Operation")
        end)

      assert log =~ "Operation"
    end

    test "works with nil default value" do
      assert is_nil(ErrorHelpers.handle_error_with_default({:error, :reason}, nil))
    end
  end

  describe "handle_error_with_warning/3" do
    test "returns value from ok tuple" do
      assert ErrorHelpers.handle_error_with_warning({:ok, 99}, 0) == 99
    end

    test "returns default on error tuple with warning log" do
      log =
        capture_log(fn ->
          result = ErrorHelpers.handle_error_with_warning({:error, :not_found}, "default")
          assert result == "default"
        end)

      assert log =~ "continuing anyway"
    end

    test "returns default on unexpected result with warning log" do
      log =
        capture_log(fn ->
          result = ErrorHelpers.handle_error_with_warning(:weirdval, "fallback")
          assert result == "fallback"
        end)

      assert log =~ "continuing anyway"
    end

    test "includes context prefix in log" do
      log =
        capture_log(fn ->
          ErrorHelpers.handle_error_with_warning({:error, :oops}, "x", "SomeContext")
        end)

      assert log =~ "SomeContext"
    end
  end
end
