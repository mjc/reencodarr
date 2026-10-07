defmodule ReencodarrWeb.WorkbenchComponents do
  @moduledoc "Shared page structure, list controls, and feedback."
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :trigger_class, :string, default: "workbench-button"
  slot :trigger, required: true
  slot :inner_block, required: true

  def dropdown(assigns) do
    ~H"""
    <details
      id={@id}
      class={@class}
      phx-mounted={JS.ignore_attributes("open")}
      phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
      phx-window-keydown={
        JS.focus(to: "##{@id}[open] > summary") |> JS.remove_attribute("open", to: "##{@id}")
      }
      phx-key="escape"
    >
      <summary class={@trigger_class}>{render_slot(@trigger)}</summary>
      {render_slot(@inner_block)}
    </details>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="page-heading">
      <div>
        <h1>{@title}</h1><p :if={@subtitle}>{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="page-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["content-panel", @class]}>
      <h2 :if={@title} class="panel-heading">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="empty-state" role="status">
      <h2>{@title}</h2><p :if={@description}>{@description}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :count, :integer, required: true
  attr :on_clear, :string, required: true
  slot :inner_block, required: true

  def selection_bar(assigns) do
    ~H"""
    <div :if={@count > 0} class="selection-toolbar" role="group" aria-label="Selected items">
      <strong role="status">{@count} selected</strong>
      {render_slot(@inner_block)}
      <button type="button" phx-click={@on_clear} class="section-action">Clear selection</button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: ""
  attr :placeholder, :string, default: nil
  attr :rest, :global, include: ~w(phx-debounce)

  def search_field(assigns) do
    ~H"""
    <label class="filter-field filter-search" for={@id}>
      <span>{@label}</span>
      <input
        id={@id}
        type="search"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class="filter-control"
        data-role="list-search-input"
        {@rest}
      />
    </label>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true

  def select_field(assigns) do
    ~H"""
    <label class="filter-field" for={@id}>
      <span>{@label}</span>
      <select id={@id} name={@name} class="filter-control" data-role="list-filter-select">
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
    </label>
    """
  end

  attr :loading, :boolean, required: true
  attr :empty, :boolean, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  def list_results(assigns) do
    ~H"""
    <section class="list-results" aria-label={@label} aria-busy={to_string(@loading)}>
      <%= if @loading and @empty do %>
        <div class="content-panel list-loading" role="status">Loading {@label}…</div>
      <% else %>
        <p :if={@loading} class="list-refreshing" role="status">Refreshing results…</p>
        {render_slot(@inner_block)}
      <% end %>
    </section>
    """
  end
end
