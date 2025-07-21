# Configure ExUnit
ExUnit.configure(
  exclude: [:flaky, :integration, :slow],
  formatters: [ExUnit.CLIFormatter],
  max_failures: :infinity,
  trace: System.get_env("TRACE_TESTS") == "true",
  # 60 seconds for slow tests
  timeout: 60_000
)

ExUnit.start()

# Configure Ecto sandbox for test isolation
Ecto.Adapters.SQL.Sandbox.mode(Reencodarr.Repo, :manual)

# Add test tags for better organization
defmodule Reencodarr.TestTags do
  @moduledoc """
  Common test tags for organizing and filtering tests:

  - @tag :slow - Tests that take more than a few seconds
  - @tag :integration - Tests that require external services
  - @tag :flaky - Tests that sometimes fail due to timing/external factors
  - @tag :unit - Pure unit tests (fast, no external dependencies)
  - @tag :db - Tests that use the database
  - @tag :broadway - Tests for Broadway pipelines
  - @tag :media - Tests related to media processing
  - @tag :property - Property-based tests using StreamData
  """

  def slow, do: :slow
  def integration, do: :integration
  def flaky, do: :flaky
  def unit, do: :unit
  def db, do: :db
  def broadway, do: :broadway
  def media, do: :media
  def property, do: :property
end
