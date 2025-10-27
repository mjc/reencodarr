defmodule Reencodarr.Encoder do
  @moduledoc """
  Public API for the Encoder pipeline.

  Provides convenient functions for controlling and monitoring the Encoder
  Broadway pipeline that performs the final video encoding after CRF searches.
  """

  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.Media

  # Control functions

  @doc "Start/resume the encoder pipeline"
  def start, do: Producer.resume()

  @doc "Pause the encoder pipeline"
  def pause, do: Producer.pause()

  @doc "Resume the encoder pipeline (alias for start)"
  def resume, do: Producer.resume()

  @doc "Force dispatch of available work"
  def dispatch_available, do: Producer.dispatch_available()

  # Status functions

  @doc "Check if the encoder is running (user intent)"
  def running?, do: Producer.running?()

  @doc "Check if the encoder is actively processing work"
  def actively_running? do
    # Simple: encoder is NOT available means it's busy encoding
    not available?()
  end

  @doc "Check if the encode GenServer is available"
  def available?, do: Encode.available?()

  @doc "Get the current state of the encoder pipeline"
  def status do
    %{
      running: running?(),
      actively_running: actively_running?(),
      available: available?(),
      queue_count: Media.encoding_queue_count()
    }
  end

  # Queue management

  @doc "Get count of videos needing encoding"
  def queue_count, do: Media.encoding_queue_count()

  @doc "Get next videos in the encoding queue"
  def next_videos(limit \\ 10), do: Media.get_next_for_encoding(limit)
end
