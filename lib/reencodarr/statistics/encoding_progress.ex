defmodule Reencodarr.Statistics.EncodingProgress do
  @moduledoc "Represents the progress of an encoding operation."

  @type t :: %__MODULE__{
          filename: :none | String.t(),
          percent: non_neg_integer(),
          eta: non_neg_integer(),
          fps: non_neg_integer()
        }

  defstruct filename: :none, percent: 0, eta: 0, fps: 0
end
