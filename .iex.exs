IEx.configure(auto_reload: true)

alias Reencodarr.AbAv1
alias Reencodarr.Media
alias Reencodarr.Media.{Video, Library, Vmaf}
alias Reencodarr.Repo
alias Reencodarr.Rules
alias Reencodarr.{Analyzer, ManualScanner}
alias Reencodarr.Services
alias Reencodarr.Sync

# Distributed system aliases
alias Reencodarr.Distributed.Coordinator
alias Reencodarr.SupervisionTreeHelper
alias Reencodarr.SupervisionConfig

import Ecto.Query

# Helper functions for debugging the supervision tree
defmodule IExHelpers do
  @moduledoc """
  Helper functions available in IEx for debugging and inspecting the system.
  """

  def tree, do: SupervisionTreeHelper.print_tree()
  def health, do: SupervisionTreeHelper.health_check()
  def restart(supervisor), do: SupervisionTreeHelper.restart_supervisor(supervisor)
  
  def cluster_info, do: Coordinator.cluster_info()
  def nodes, do: [Node.self() | Node.list()]
  
  def node_mode, do: SupervisionConfig.node_mode()
  def capabilities, do: SupervisionConfig.node_capabilities()
end

import IExHelpers

IO.puts """

=== Reencodarr IEx Helpers ===
Available functions:
  • tree()           - Print supervision tree
  • health()         - Check supervisor health
  • restart(sup)     - Restart a supervisor
  • cluster_info()   - Show cluster status
  • nodes()          - List connected nodes
  • node_mode()      - Show current node mode
  • capabilities()   - Show node capabilities

Examples:
  iex> tree()
  iex> health()
  iex> cluster_info()
  iex> restart(Reencodarr.WebSupervisor)

"""
