defmodule Reencodarr.Encoder.Consumer do
  use GenStage
  require Logger
  alias Reencodarr.AbAv1

  def start_link() do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:consumer, :ok, subscribe_to: [{Reencodarr.Encoder.Producer, max_demand: 1}]}
  end

  @impl true
  def handle_events(vmafs, _from, state) do
    for vmaf <- vmafs do
      try do
        Logger.info("Starting encoding for #{vmaf.video.path}")
        # AbAv1.encode expects a VMAF struct
        AbAv1.encode(vmaf)

        # Block until encoding is actually complete
        wait_for_encoding_completion()

        Logger.info("Completed encoding for #{vmaf.video.path}")
      rescue
        e ->
          Logger.error("Encoding failed for #{vmaf.video.path}: #{inspect(e)}")
          # Optionally mark video as failed or retry logic here
      end
    end

    {:noreply, [], state}
  end

  # Poll the encoding status until it's no longer running
  defp wait_for_encoding_completion() do
    case GenServer.call(Reencodarr.AbAv1.Encode, :running?) do
      :running ->
        # Still running, wait a bit and check again
        Process.sleep(1000)  # Use longer sleep for encoding as it takes much longer
        wait_for_encoding_completion()
      :not_running ->
        # Encoding is complete
        :ok
    end
  end
end
