defmodule Reencodarr.Statistics.EncodingProgress do
  @enforce_keys [:filename, :percent, :eta, :fps]
  defstruct filename: :none, percent: 0, eta: 0, fps: 0
end
