defmodule ReencodarrWeb.Layouts do
  @moduledoc false
  use ReencodarrWeb, :html

  attr :active, :atom, required: true

  def issue_tabs(assigns) do
    ~H"""
    <nav class="issue-tabs" aria-label="Issue type">
      <.link navigate={~p"/failures"} aria-current={if(@active == :failures, do: "page")}>Failures</.link>
      <.link navigate={~p"/bad-files"} aria-current={if(@active == :bad_files, do: "page")}>Bad files</.link>
    </nav>
    """
  end

  embed_templates "layouts/*"
end
