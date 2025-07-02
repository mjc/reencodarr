defmodule Reencodarr.Encoder.Consumer do
  @moduledoc """
  GenStage consumer for processing encoding operations.

  This consumer subscribes to the Encoder.Producer and processes videos
  by initiating encoding using the base consumer pattern.
  """

  use Reencodarr.GenStage.BaseConsumer

  alias Reencodarr.AbAv1

  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @impl Reencodarr.GenStage.BaseConsumer
  def process_item(vmaf) do
    AbAv1.encode(vmaf)
    :ok
  end

  @impl Reencodarr.GenStage.BaseConsumer
  def completion_event_topic, do: "encoding_events"

  @impl Reencodarr.GenStage.BaseConsumer
  def item_id(vmaf), do: vmaf.id

  @impl Reencodarr.GenStage.BaseConsumer
  def producer_module, do: Reencodarr.Encoder.Producer

  @impl Reencodarr.GenStage.BaseConsumer
  def log_start(vmaf) do
    Logger.info("Starting encoding for #{vmaf.video.path}")
    :ok
  end

  @impl Reencodarr.GenStage.BaseConsumer
  def log_completion(vmaf_id, result) do
    case result do
      :success ->
        Logger.info("Completed encoding for VMAF #{vmaf_id}")

      :skipped ->
        Logger.info("Skipped encoding for VMAF #{vmaf_id} (already in progress)")

      {:error, exit_code} ->
        Logger.error("Encoding failed for VMAF #{vmaf_id} with exit code: #{exit_code}")
    end

    :ok
  end
end
