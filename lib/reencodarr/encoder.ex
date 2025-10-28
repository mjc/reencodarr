defmodule Reencodarr.Encoder do
  @moduledoc """
  Public API for the Encoder pipeline.
  """

  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.Media

  @doc "Force dispatch of available work"
  def dispatch_available, do: Producer.dispatch_available()

  @doc "Check if the encoder is actively processing work"
  def actively_running?, do: not available?()

  @doc "Check if the encode GenServer is available"
  def available?, do: Encode.available?()

  @doc "Get the current state of the encoder pipeline"
  def status do
    %{
      running: true,
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
