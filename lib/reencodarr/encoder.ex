defmodule Reencodarr.Encoder do
  @moduledoc """
  Encoder module that uses Broadway for processing encoding operations.
  Provides backward compatibility with the old GenStage-based encoder.
  """

  require Logger
  alias Reencodarr.Encoder.Broadway
  alias Reencodarr.Encoder.Broadway.Producer

  @doc """
  Check if the encoder is currently running.

  ## Examples
      iex> Reencodarr.Encoder.running?()
      true
  """
  @spec running?() :: boolean()
  def running?, do: Broadway.running?()

  @doc """
  Start the encoder.
  """
  @spec start() :: :ok
  def start do
    Logger.info("🎬 Starting encoder")
    Logger.info("🎬 Calling Broadway.start()")
    result = Broadway.start()
    Logger.info("🎬 Broadway.start() returned: #{inspect(result)}")

    # Trigger dispatch of available VMAFs
    Logger.info("🎬 Calling Broadway Producer dispatch_available()")
    dispatch_result = Producer.dispatch_available()
    Logger.info("🎬 dispatch_available() returned: #{inspect(dispatch_result)}")
    :ok
  end

  @doc """
  Pause the encoder.
  """
  @spec pause() :: :ok
  def pause do
    Logger.info("🎬 Pausing encoder")
    Broadway.pause()
    :ok
  end

  @doc """
  Resume the encoder.
  """
  @spec resume() :: :ok
  def resume do
    Logger.info("🎬 Resuming encoder")
    Broadway.resume()
    :ok
  end

  @doc """
  Process a VMAF for encoding.

  ## Parameters
    * `vmaf` - VMAF struct containing encoding parameters

  ## Examples
      iex> vmaf = %{id: 1, video: %{path: "/path/to/video.mp4"}}
      iex> Reencodarr.Encoder.process_vmaf(vmaf)
      :ok
  """
  @spec process_vmaf(map()) :: :ok
  def process_vmaf(vmaf) do
    Logger.debug("🎬 Processing VMAF for encoding: #{vmaf.video.path}")
    Broadway.process_vmaf(vmaf)
    :ok
  end

  @doc """
  Dispatch available work to the encoder.

  This function is called when new work becomes available.
  """
  @spec dispatch_available() :: :ok
  def dispatch_available do
    Producer.dispatch_available()
  end
end
