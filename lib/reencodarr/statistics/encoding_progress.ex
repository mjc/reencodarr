defmodule Reencodarr.Statistics.EncodingProgress do
  @moduledoc "Represents the progress of an encoding operation."

  defstruct filename: :none, percent: 0, eta: 0, fps: 0
end
