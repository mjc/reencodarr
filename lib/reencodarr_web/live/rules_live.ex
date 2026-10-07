defmodule ReencodarrWeb.RulesLive do
  @moduledoc "Encoding reference with bookmarkable sections."
  use ReencodarrWeb, :live_view

  alias ReencodarrWeb.RulesLive.Sections

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Encoding rules", sections: Sections.all())}

  @impl true
  def handle_params(params, _uri, socket) do
    section = Sections.find(Map.get(params, "section", "overview"))
    {:noreply, assign(socket, :section, section)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="workbench page-stack">
      <.page_header title="Encoding rules" subtitle="Current encoding and quality settings." />
      <div class="reference-layout">
        <nav class="reference-nav" aria-label="Rule sections">
          <.link
            :for={section <- @sections}
            patch={~p"/rules?#{%{section: section.id}}"}
            aria-current={if(@section.id == section.id, do: "page")}
          >{section.title}</.link>
        </nav>
        <.panel id="rule-section" title={@section.title}>
          <p class="reference-description">{@section.description}</p>
          <dl class="reference-facts">
            <div :for={{label, value} <- @section.facts}>
              <dt>{label}</dt><dd>{value}</dd>
            </div>
          </dl>
          <pre :if={@section[:example]} class="command-example"><code>{@section.example}</code></pre>
        </.panel>
      </div>
    </div>
    """
  end
end
