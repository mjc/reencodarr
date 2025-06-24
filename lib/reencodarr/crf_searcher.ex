defmodule Reencodarr.CrfSearcher do
  @moduledoc """
  Backward compatibility wrapper for the new GenStage-based CrfSearcher.

  This module provides the same API as the old GenServer-based CrfSearcher
  but delegates to the new GenStage Producer.
  """

  def start, do: Reencodarr.CrfSearcher.Producer.start()
  def pause, do: Reencodarr.CrfSearcher.Producer.pause()
  def running?, do: Reencodarr.CrfSearcher.Producer.running?()

  # Deprecated aliases for compatibility
  def start_searching, do: start()
  def pause_searching, do: pause()
  def scanning?, do: running?()
  def searching?, do: running?()
end
