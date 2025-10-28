defmodule Reencodarr.CrfSearcher.Supervisor do
  use Supervisor

  @moduledoc "Supervises CRF search-related processes."

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @impl true
  def init(:ok) do
    children = [
      {Reencodarr.AbAv1.CrfSearch, []},
      {Reencodarr.CrfSearcher.Broadway, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Start the Broadway pipeline under this supervisor if not already running.
  """
  def start_broadway do
    case Process.whereis(Reencodarr.CrfSearcher.Broadway) do
      nil ->
        spec = {Reencodarr.CrfSearcher.Broadway, []}
        Supervisor.start_child(__MODULE__, spec)

      _pid ->
        {:error, :already_started}
    end
  end

  @doc """
  Stop the Broadway pipeline if running.
  """
  def stop_broadway do
    case Process.whereis(Reencodarr.CrfSearcher.Broadway) do
      nil ->
        :ok

      _pid ->
        Supervisor.terminate_child(__MODULE__, Reencodarr.CrfSearcher.Broadway)
        Supervisor.delete_child(__MODULE__, Reencodarr.CrfSearcher.Broadway)
    end
  end
end
