defmodule Reencodarr.UnitCase do
  @moduledoc """
  This module defines the setup for pure unit tests.

  Use this for tests that:
  - Test pure functions with no external dependencies
  - Don't need database or connection setup
  - Test utility functions, formatters, parsers, etc.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Tests can import TestHelpers if needed
    end
  end

  setup _tags do
    :ok
  end
end
