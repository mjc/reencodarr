defmodule Reencodarr.AbAv1 do
  @moduledoc """
  Supervisor for AV1 CRF search and encode workers.

  Provides functions to queue CRF searches and encodes, and to check queue lengths.
  """

  use Supervisor
  require Logger

  alias Reencodarr.AbAv1.QueueManager
  alias Reencodarr.Media

  ## Public API

  @doc """
  Starts the `#{inspect(__MODULE__)}` supervisor.
  """
  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Returns the message queue lengths for the CRF search and encode GenServers.

      iex> #{inspect(__MODULE__)}.queue_length()
      %{crf_searches: 0, encodes: 0}
  """
  @spec queue_length() :: %{crf_searches: non_neg_integer(), encodes: non_neg_integer()}
  def queue_length do
    servers = [
      {:crf_searches, Reencodarr.AbAv1.CrfSearch},
      {:encodes, Reencodarr.AbAv1.Encode}
    ]

    QueueManager.calculate_queue_lengths(servers)
  end

  @doc """
  Queues a CRF search for the given video and VMAF percent (default: 95).

  ## Parameters

    - `video`: a `%Media.Video{}` struct
    - `vmaf_percent`: integer (default: 95)
  """
  @spec crf_search(Media.Video.t(), integer()) :: :ok | {:error, atom()}
  def crf_search(video, vmaf_percent \\ 95) do
    case QueueManager.validate_crf_search_request(video, vmaf_percent) do
      {:ok, {validated_video, validated_percent}} ->
        message = QueueManager.build_crf_search_message(validated_video, validated_percent)
        GenServer.cast(Reencodarr.AbAv1.CrfSearch, message)
        :ok

      {:error, reason} ->
        Logger.warning("Invalid CRF search request: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Queues an encode for the given VMAF result.

  ## Parameters

    - `vmaf`: a `%Media.Vmaf{}` struct
  """
  @spec encode(Media.Vmaf.t()) :: :ok | {:error, atom()}
  def encode(vmaf) do
    # Skip MP4 files - compatibility issues to be resolved later
    video_id = Map.get(vmaf, :video_id) || Map.get(vmaf, "video_id")

    if is_integer(video_id) do
      try do
        video = Media.get_video!(video_id)

        if is_binary(video.path) and String.ends_with?(video.path, ".mp4") do
          # Skip MP4 files - compatibility issues
          Logger.info("Skipping encode for MP4 file (compatibility issues): #{video.path}")
          # Mark as failed to skip future encoding attempts
          case Media.mark_as_failed(video) do
            {:ok, _updated} -> :ok
            error -> error
          end
        else
          do_queue_encode(vmaf)
        end
      rescue
        Ecto.NoResultsError ->
          # Video doesn't exist - fall back to normal validation/queuing
          do_queue_encode(vmaf)
      end
    else
      do_queue_encode(vmaf)
    end
  end

  defp do_queue_encode(vmaf) do
    case QueueManager.validate_encode_request(vmaf) do
      {:ok, validated_vmaf} ->
        message = QueueManager.build_encode_message(validated_vmaf)
        GenServer.cast(Reencodarr.AbAv1.Encode, message)
        :ok

      {:error, reason} ->
        Logger.warning("Invalid encode request: #{reason}")
        {:error, reason}
    end
  end

  ## Supervisor Callbacks

  @doc false
  def init(:ok) do
    children = [
      Reencodarr.AbAv1.Encode
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
