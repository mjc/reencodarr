defmodule Reencodarr.Encoder do
  @moduledoc """
  Public API for the Encoder pipeline.
  """

  alias Reencodarr.AbAv1.{Encode, WorkerConfig, WorkerSessions}
  alias Reencodarr.AbAv1.WorkerSessions.Job
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.Media

  @doc "Force dispatch of available work"
  def dispatch_available, do: Producer.dispatch_available()

  @doc "Suspend the active encode OS process and gate future dispatch"
  def suspend_current, do: Encode.suspend_current()

  @doc "Resume the active encode OS process and ungate dispatch"
  def resume_current, do: Encode.resume_current()

  @doc "Fail the active encode job"
  def fail_current, do: Encode.fail_current()

  @doc "Check if the encoder is actively processing work"
  def actively_running?, do: available?() != :available

  @doc "Check if an encoder is available"
  def available? do
    case WorkerConfig.execution_mode() do
      :broadway -> Encode.available?()
      :worker -> if worker_encode_active?(), do: :processing, else: :available
    end
  end

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

  defp worker_encode_active? do
    Process.whereis(WorkerSessions) != nil and
      Enum.any?(WorkerSessions.list(), fn session ->
        Enum.any?(session.jobs, fn {_job_id, job} -> match?(%Job{job_type: :encode}, job) end)
      end)
  end
end
