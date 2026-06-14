defmodule Reencodarr.UnitCase do
  @moduledoc false

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
