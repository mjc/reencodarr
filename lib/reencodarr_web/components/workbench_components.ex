defmodule ReencodarrWeb.WorkbenchComponents do
  @moduledoc "Shared page, panel, and empty-state components."
  use Phoenix.Component

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
end
