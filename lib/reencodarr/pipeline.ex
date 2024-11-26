defmodule Reencodarr.Pipeline do
  use DynamicSupervisor

  @moduledoc """
    Convenience methods for working with the pipelines that power Reencodarr.
  """

  def start_link(_init_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_video_scanner(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_video_scanner(path) do
    spec = {Reencodarr.Pipeline.Scanner.Video, path: path}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
