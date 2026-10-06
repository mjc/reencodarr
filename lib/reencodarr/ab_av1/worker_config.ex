defmodule Reencodarr.AbAv1.WorkerConfig do
  @moduledoc """
  Runtime configuration for distributed ab-av1 workers.
  """

  @default_chunk_size_bytes 134_217_728

  @spec execution_mode() :: :broadway | :worker
  def execution_mode do
    case Application.get_env(:reencodarr, :crf_execution_mode, :broadway) do
      mode when mode in [:broadway, "broadway"] ->
        :broadway

      mode when mode in [:worker, "worker"] ->
        :worker

      mode ->
        raise ArgumentError,
              "invalid CRF execution mode #{inspect(mode)}; expected broadway or worker"
    end
  end

  @spec supervise_local_worker?() :: boolean()
  def supervise_local_worker? do
    Application.get_env(:reencodarr, :supervise_local_worker, true)
  end

  @spec local_worker_config!() :: map()
  def local_worker_config! do
    %{
      executable: Application.get_env(:reencodarr, :worker_executable, "ab-av1"),
      connect_url:
        :reencodarr
        |> Application.get_env(:worker_connect_url, "http://127.0.0.1:4000")
        |> String.trim_trailing("/"),
      token: fetch_required!(:worker_token),
      worker_id:
        Application.get_env(:reencodarr, :worker_id) ||
          System.get_env("HOSTNAME") || "reencodarr-local",
      extra_args: Application.get_env(:reencodarr, :worker_extra_args, []),
      restart_base_ms: Application.get_env(:reencodarr, :worker_restart_base_ms, 1_000),
      restart_max_ms: Application.get_env(:reencodarr, :worker_restart_max_ms, 30_000)
    }
  end

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

  @spec transfer_base_url() :: String.t() | nil
  def transfer_base_url do
    case Application.get_env(:reencodarr, :worker_transfer_base_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  @spec transfer_token() :: String.t() | nil
  def transfer_token do
    Application.get_env(:reencodarr, :worker_transfer_token) ||
      Application.get_env(:reencodarr, :worker_token)
  end

  defp fetch_required!(key) do
    case Application.get_env(:reencodarr, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "missing required Reencodarr worker configuration: #{key}"
    end
  end
end
