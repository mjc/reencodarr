defmodule Reencodarr.TestHelpers do
  @moduledoc """
  Test helpers and assertion utilities for the Reencodarr test suite.

  This module provides common test utilities that are automatically imported
  into test cases via DataCase, focusing on:

  - Argument parsing and validation
  - Custom assertions for domain-specific testing
  - Pattern matching helpers
  - Flag finding and validation utilities
  """

  import ExUnit.Assertions
  alias Reencodarr.Analyzer.Broadway, as: AnalyzerBroadway

  # === ARGUMENT PARSING HELPERS ===

  @doc """
  Finds all indices where a specific flag appears in an argument list.

  ## Examples

      iex> find_flag_indices(["--preset", "6", "--svt", "tune=0", "--preset", "4"], "--preset")
      [0, 4]
  """
  def find_flag_indices(args, flag) do
    args
    |> Enum.with_index()
    |> Enum.filter(fn {arg, _} -> arg == flag end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Asserts that a flag with a specific value is present in an argument list.
  """
  def assert_flag_value_present(args, flag, expected_value) do
    assert find_flag_value(args, flag, expected_value),
           "Expected to find #{flag} with value #{expected_value} in #{inspect(args)}"
  end

  @doc """
  Checks if a flag has a specific value in an argument list.

  ## Examples

      iex> find_flag_value(["--preset", "6", "--svt", "tune=0"], "--preset", "6")
      true

      iex> find_flag_value(["--preset", "4", "--svt", "tune=0"], "--preset", "6")
      false
  """
  def find_flag_value(args, flag, expected_value) do
    indices = find_flag_indices(args, flag)

    Enum.any?(indices, fn idx ->
      value = Enum.at(args, idx + 1)
      value == expected_value
    end)
  end

  # === DATABASE TESTING HELPERS ===

  @doc """
  Asserts that a database operation changes the count of records by the expected amount.
  """
  def assert_database_state(schema, expected_count_change, fun) do
    initial_count = Reencodarr.Repo.aggregate(schema, :count, :id)

    result = fun.()

    final_count = Reencodarr.Repo.aggregate(schema, :count, :id)
    actual_change = final_count - initial_count

    assert actual_change == expected_count_change,
           "Expected #{schema} count to change by #{expected_count_change}, but it changed by #{actual_change}"

    result
  end

  # === TEMPORARY FILE HELPERS ===

  @doc """
  Creates a temporary file with the given content and extension,
  executes the given function with the file path, then cleans up.
  """
  def with_temp_file(content, extension, fun) do
    temp_dir = System.tmp_dir!()
    unique_id = System.unique_integer([:positive])
    temp_file = Path.join(temp_dir, "test_file_#{unique_id}#{extension}")

    File.write!(temp_file, content)

    try do
      fun.(temp_file)
    after
      File.rm(temp_file)
    end
  end

  # === BROADWAY TESTING HELPERS ===

  @doc """
  Helper for testing Broadway error handling scenarios.
  """
  def test_broadway_error_handling(_broadway_module, _message) do
    # Trigger Broadway dispatch to test error handling
    AnalyzerBroadway.dispatch_available()
  end
end
