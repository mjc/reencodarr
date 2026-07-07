defmodule Reencodarr.AbAv1.WorkerConfig do
  @moduledoc """
  Runtime configuration for distributed ab-av1 workers.
  """

  @default_chunk_size_bytes 1_048_576

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:reencodarr, :distributed_worker_enabled, false)
  end

  @spec enable() :: :ok
  def enable do
    Application.put_env(:reencodarr, :distributed_worker_enabled, true)
    :ok
  end

  @spec disable() :: :ok
  def disable do
    Application.put_env(:reencodarr, :distributed_worker_enabled, false)
    :ok
  end

  @spec chunk_size_bytes() :: pos_integer()
  def chunk_size_bytes do
    Application.get_env(:reencodarr, :worker_chunk_size_bytes, @default_chunk_size_bytes)
  end

  @spec transfer_window() :: pos_integer()
  def transfer_window do
    Application.get_env(:reencodarr, :worker_transfer_window, 1)
  end

  @spec retry_limit() :: non_neg_integer()
  def retry_limit do
    Application.get_env(:reencodarr, :worker_retry_limit, 3)
  end

  @spec transfer_timeout_ms() :: pos_integer()
  def transfer_timeout_ms do
    Application.get_env(:reencodarr, :worker_transfer_timeout_ms, 60_000)
  end

  @spec max_concurrent_transfers() :: pos_integer()
  def max_concurrent_transfers do
    Application.get_env(:reencodarr, :worker_max_concurrent_transfers, 1)
  end
end
