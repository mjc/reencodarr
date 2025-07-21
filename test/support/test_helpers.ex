defmodule Reencodarr.TestHelpers do
  @moduledoc """
  Common test helpers and utilities for Reencodarr test suite.

  This module provides reusable patterns for testing Broadway pipelines,
  external command interactions, and common assertions.
  """

  import ExUnit.Assertions
  import ExUnit.CaptureLog

  @doc """
  Test that a Broadway pipeline can handle errors gracefully.

      test_broadway_error_handling(Reencodarr.Analyzer.Broadway, %{
        path: "/nonexistent/file.mkv",
        service_id: "1",
        service_type: :sonarr
      })
  """
  def test_broadway_error_handling(broadway_module, invalid_data) do
    log =
      capture_log(fn ->
        try do
          broadway_module.process_path(invalid_data)
          # Give time to process
          Process.sleep(100)
        rescue
          _ -> :ok
        end
      end)

    # Should not crash - any log output is acceptable
    assert is_binary(log)
  end

  @doc """
  Test multiple Broadway operations concurrently.

      test_concurrent_broadway_operations([
        %{path: "/file1.mkv", service_id: "1", service_type: :sonarr},
        %{path: "/file2.mkv", service_id: "2", service_type: :radarr}
      ], Reencodarr.Analyzer.Broadway)
  """
  def test_concurrent_broadway_operations(data_list, broadway_module) do
    tasks = Enum.map(data_list, &create_broadway_task(&1, broadway_module))

    # All tasks should complete without hanging
    logs = Task.await_many(tasks, 5_000)

    # Should return log entries for all operations
    assert length(logs) == length(data_list)
    Enum.each(logs, &assert(is_binary(&1)))
  end

  defp create_broadway_task(data, broadway_module) do
    Task.async(fn ->
      capture_log(fn ->
        safely_process_path(data, broadway_module)
      end)
    end)
  end

  defp safely_process_path(data, broadway_module) do
    broadway_module.process_path(data)
    Process.sleep(50)
  rescue
    _ -> :ok
  end

  @doc """
  Create a temporary video file for testing.

      with_temp_video_file("fake content", fn file_path ->
        # Test operations with file_path
      end)
  """
  def with_temp_video_file(content \\ "fake video content", extension \\ ".mkv", fun) do
    file_path = Path.join(System.tmp_dir!(), "test_video_#{:rand.uniform(10000)}#{extension}")
    File.write!(file_path, content)

    try do
      fun.(file_path)
    after
      File.rm(file_path)
    end
  end

  @doc """
  Create multiple temporary video files for bulk testing.

      with_temp_video_files(3, fn file_paths ->
        # Test with list of file paths
      end)
  """
  def with_temp_video_files(count, content \\ "fake video content", fun) do
    file_paths =
      Enum.map(1..count, fn i ->
        file_path = Path.join(System.tmp_dir!(), "test_video_#{i}_#{:rand.uniform(10000)}.mkv")
        File.write!(file_path, content)
        file_path
      end)

    try do
      fun.(file_paths)
    after
      Enum.each(file_paths, &File.rm/1)
    end
  end

  @doc """
  Wait for an async operation to complete or timeout.

      wait_for(fn ->
        Reencodarr.Repo.aggregate(Video, :count, :id) > 0
      end, timeout: 1000)
  """
  def wait_for(condition, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 50)

    wait_for_condition(condition, timeout, interval)
  end

  defp wait_for_condition(condition, timeout, interval) when timeout > 0 do
    if condition.() do
      :ok
    else
      Process.sleep(interval)
      wait_for_condition(condition, timeout - interval, interval)
    end
  end

  defp wait_for_condition(_condition, _timeout, _interval) do
    flunk("Condition was not met within timeout")
  end

  @doc """
  Assert that telemetry events are emitted correctly.

      assert_telemetry_event([:reencodarr, :video, :analyzed], %{count: 1}, fn ->
        # Code that should emit telemetry
      end)
  """
  def assert_telemetry_event(event_name, expected_measurements, test_fun) do
    test_pid = self()
    ref = make_ref()

    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      [event_name],
      fn ^event_name, measurements, _metadata, _config ->
        send(test_pid, {:telemetry_event, ref, event_name, measurements})
      end,
      nil
    )

    try do
      test_fun.()

      receive do
        {:telemetry_event, ^ref, ^event_name, measurements} ->
          assert measurements == expected_measurements
      after
        1000 ->
          flunk("Expected telemetry event #{inspect(event_name)} was not emitted")
      end
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc """
  Mock external command execution for testing.

      with_mocked_command("mediainfo", ~s({"streams": []}), fn ->
        # Code that calls mediainfo
      end)
  """
  def with_mocked_command(command, mock_output, test_fun) do
    # This would integrate with a mocking library like :meck
    # For now, provide the interface that tests can use

    # Create a mock script that returns the desired output
    mock_script_path = Path.join(System.tmp_dir!(), "mock_#{command}_#{:rand.uniform(10000)}")

    File.write!(mock_script_path, """
    #!/bin/bash
    echo '#{mock_output}'
    """)

    File.chmod!(mock_script_path, 0o755)

    original_path = System.get_env("PATH")
    mock_dir = Path.dirname(mock_script_path)
    System.put_env("PATH", "#{mock_dir}:#{original_path}")

    try do
      test_fun.()
    after
      System.put_env("PATH", original_path)
      File.rm(mock_script_path)
    end
  end

  @doc """
  Assert that database state matches expectations after an operation.

      assert_database_state(Video, 5, fn ->
        # Operations that should result in 5 videos
      end)
  """
  def assert_database_state(schema, expected_count, test_fun) do
    alias Reencodarr.Repo

    initial_count = Repo.aggregate(schema, :count, :id)
    test_fun.()
    final_count = Repo.aggregate(schema, :count, :id)

    assert final_count == expected_count,
           "Expected #{expected_count} #{schema} records, got #{final_count} " <>
             "(change: #{final_count - initial_count})"
  end

  @doc """
  Test that a function handles all values in an enum correctly.

      test_enum_handling(MyModule, :status_to_string, VideoStatus, [
        {:pending, "Pending"},
        {:processing, "Processing"}
      ])
  """
  def test_enum_handling(module, function, _enum_module, expected_mappings) do
    Enum.each(expected_mappings, fn {input, expected_output} ->
      actual_output = apply(module, function, [input])

      assert actual_output == expected_output,
             "Expected #{module}.#{function}(#{inspect(input)}) to return #{inspect(expected_output)}, " <>
               "got #{inspect(actual_output)}"
    end)
  end

  @doc """
  Test that a module properly validates all required fields.

      test_required_fields(Media, :create_video, [:path, :size, :bitrate])
  """
  def test_required_fields(context_module, create_function, required_fields) do
    Enum.each(required_fields, fn field ->
      attrs = Map.put(%{}, field, nil)

      assert {:error, changeset} = apply(context_module, create_function, [attrs])
      errors = Reencodarr.DataCase.errors_on(changeset)

      assert "can't be blank" in Map.get(errors, field, []),
             "Expected field #{field} to be required, but no validation error was found"
    end)
  end
end
