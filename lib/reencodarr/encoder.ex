defmodule Reencodarr.Encoder do
  @moduledoc """
  Backward compatibility wrapper for the new GenStage-based Encoder.

  This module provides the same API as the old GenServer-based Encoder
  but delegates to the new GenStage Producer.
  """

  def start, do: Reencodarr.Encoder.Producer.start()
  def pause, do: Reencodarr.Encoder.Producer.pause()
  def running?, do: Reencodarr.Encoder.Producer.running?()

  # Deprecated aliases for compatibility
  def start_encoding, do: start()
  def pause_encoding, do: pause()
  def encoding?, do: running?()

  # For compatibility with old Media module calls
  def get_next_for_encoding, do: Reencodarr.Media.get_next_for_encoding()
end
