defmodule ReencodarrWeb.SourceComponents do
  @moduledoc "Source controls and persisted sync schedule."
  use ReencodarrWeb, :html

  alias Reencodarr.{Formatters, Sync}

  attr :config, :map, required: true
  attr :sync, :map, default: nil
  attr :id, :string, required: true

  def source(assigns) do
    assigns =
      assign(
        assigns,
        :sync_supported,
        assigns.config.service_type in [:sonarr, :sportarr, :radarr]
      )

    ~H"""
    <article id={@id} class="source-card content-panel">
      <header>
        <div>
          <h2>{Phoenix.Naming.humanize(@config.service_type)}</h2>
          <p class="source-url">{@config.url}</p>
        </div>
        <button
          role="switch"
          aria-checked={to_string(@config.enabled)}
          aria-label={"Enable #{Phoenix.Naming.humanize(@config.service_type)}"}
          phx-click="toggle_enabled"
          phx-value-id={@config.id}
          class="setting-switch"
        >
          <span aria-hidden="true" />{if(@config.enabled, do: "Enabled", else: "Disabled")}
        </button>
      </header>
      <div class="source-sync-status" id={"source-status-#{@config.id}"}>
        <%= cond do %>
          <% @sync && @sync.status in [:queued, :syncing] -> %>
            <div class="source-progress-label">
              <span>{if(@sync.status == :queued, do: "Queued", else: "Syncing")}</span><span>{@sync.progress}%</span>
            </div>
            <progress
              max="100"
              value={@sync.progress}
              aria-label={"#{@config.service_type} sync progress"}
            />
          <% @sync && @sync.status == :failed -> %>
            <p role="alert" class="text-rose-300">
              Sync failed. Check the source connection and try again.
            </p>
          <% @sync_supported -> %>
            <p>
              Last sync:
              <strong>{if(@config.last_synced_at,
                do: Formatters.relative_time(@config.last_synced_at),
                else: "Never synced"
              )}</strong>
            </p>
            <p class="text-[var(--wb-muted)]">{schedule_label(@config)}</p>
          <% true -> %>
            <p class="text-[var(--wb-muted)]">This service has no media sync.</p>
        <% end %>
      </div>
      <footer>
        <button
          :if={@sync_supported}
          phx-click="sync_source"
          phx-value-id={@config.id}
          disabled={(not @config.enabled or (@sync && @sync.status in [:queued, :syncing])) || false}
          class="workbench-button"
        >Sync now</button>
        <.link patch={~p"/configs/#{@config}/edit"} class="section-action">Edit</.link>
        <details
          id={"source-settings-#{@config.id}"}
          phx-mounted={JS.ignore_attributes("open")}
          class="source-extra"
        >
          <summary>Details</summary>
          <p>API key: {"****" <> String.slice(@config.api_key || "", -4..-1//1)}</p>
          <.link navigate={~p"/configs/#{@config}"} class="section-action">View source</.link>
          <.link
            phx-click="delete"
            phx-value-id={@config.id}
            data-confirm="Delete this source?"
            class="text-rose-300"
          >Delete</.link>
        </details>
      </footer>
    </article>
    """
  end

  defp schedule_label(%{enabled: false}), do: "Scheduled sync is off."
  defp schedule_label(%{last_synced_at: nil}), do: "Initial sync is due."

  defp schedule_label(config) do
    seconds = div(Sync.interval_ms(), 1000)
    due = DateTime.add(config.last_synced_at, seconds, :second)
    remaining = DateTime.diff(due, DateTime.utc_now())

    if remaining <= 0,
      do: "Scheduled sync is due.",
      else: "Next sync in #{ceil(remaining / 60)} min."
  end
end
