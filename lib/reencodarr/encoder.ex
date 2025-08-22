defmodule Reencodarr.Encoder do
  @moduledoc """
  Simplified compatibility layer for Broadway encoder operations.
  
  Provides a clean API that delegates directly to Broadway modules without
  complex compatibility overhead.
  """

  alias Reencodarr.Encoder.Broadway
  alias Reencodarr.Encoder.Broadway.Producer

  @doc """
  Check if the encoder is currently running.
  """
  @spec running?() :: boolean()
  def running?, do: Broadway.running?()

  @doc """
  Start the encoder.
  """
  @spec start() :: :ok
  def start do
    Broadway.resume()
    :ok
  end

  @doc """
  Pause the encoder.
  """
  @spec pause() :: :ok
  def pause do
    Broadway.pause()
    :ok
  end

  @doc """
  Process a VMAF for encoding.
  """
  @spec process_vmaf(map()) :: :ok
  def process_vmaf(vmaf) do
    Broadway.process_vmaf(vmaf)
    :ok
  end

  @doc """
  Dispatch available work to the encoder.
  """
  @spec dispatch_available() :: :ok
  def dispatch_available do
    Producer.dispatch_available()
  end
end
