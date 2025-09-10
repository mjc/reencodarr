defmodule Mix.Tasks.SetupPrecommit do
  @moduledoc """
  Sets up git hooks for this repository.

  ## Examples

      $ mix setup_precommit

  This will:
  1. Configure git to use the .githooks directory for hooks
  2. Ensure the pre-commit hook is executable
  """
  use Mix.Task

  @shortdoc "Sets up git hooks for this repository"
  def run(_) do
    # Configure git to use .githooks directory
    {_, 0} = System.cmd("git", ["config", "core.hooksPath", ".githooks"])
    # Ensure the pre-commit hook is executable
    File.chmod!(".githooks/pre-commit", 0o755)

    IO.puts("\n✅ Git hooks have been set up successfully!")
    IO.puts("The following checks will run before each commit:")
    IO.puts("  • mix credo --strict")
    IO.puts("  • mix format --check-formatted")
    IO.puts("  • mix format --migrate --check-formatted")
  end
end
