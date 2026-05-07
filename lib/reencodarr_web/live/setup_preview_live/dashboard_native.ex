defmodule ReencodarrWeb.SetupPreviewLive.DashboardNative do
  @moduledoc false

  use Phoenix.Component

  attr :preview, :map, required: true

  def dashboard_native(assigns) do
    preview = assigns.preview || %{}
    mode = preview[:mode]
    active_service = service_label(preview[:active_service])
    services = normalize_services(preview[:services] || [], active_service)
    repair_mode? = repair_mode?(mode)

    assigns =
      assigns
      |> assign(:mode_label, mode_label(mode))
      |> assign(:mode_chip_classes, mode_chip_classes(mode))
      |> assign(:repair_mode?, repair_mode?)
      |> assign(:headline, preview[:headline] || default_headline(repair_mode?))
      |> assign(:subheadline, preview[:subheadline] || default_subheadline(repair_mode?))
      |> assign(:services, services)
      |> assign(:service_count, length(services))
      |> assign(:active_service, active_service)
      |> assign(:toast_title, preview[:toast_title] || default_toast_title(repair_mode?))
      |> assign(:toast_body, preview[:toast_body] || default_toast_body(repair_mode?))
      |> assign(:primary_steps, primary_steps(repair_mode?))
      |> assign(:secondary_steps, secondary_steps(repair_mode?))

    ~H"""
    <section class="rounded-2xl border border-gray-800 bg-gray-950/95 p-5 shadow-2xl shadow-black/30 ring-1 ring-gray-900">
      <div class="space-y-5">
        <div class="flex flex-col gap-4 border-b border-gray-800 pb-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="space-y-3">
            <div class="flex flex-wrap items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.24em] text-gray-500">
              <span>Dashboard-native operations</span>
              <span class="rounded-full border border-cyan-500/30 bg-cyan-500/10 px-2 py-1 text-cyan-300">
                Live preview
              </span>
            </div>
            <div class="space-y-1">
              <h2 class="text-2xl font-semibold tracking-tight text-gray-100">{@headline}</h2>
              <p class="max-w-3xl text-sm leading-6 text-gray-400">{@subheadline}</p>
            </div>
          </div>

          <div class="grid grid-cols-1 gap-2 sm:grid-cols-3 lg:min-w-[26rem]">
            <div class="rounded-xl border border-gray-800 bg-gray-900/80 px-3 py-2">
              <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">Mode</div>
              <div class="mt-2">
                <span class={@mode_chip_classes}>{@mode_label}</span>
              </div>
            </div>

            <div class="rounded-xl border border-gray-800 bg-gray-900/80 px-3 py-2">
              <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">Services</div>
              <div class="mt-2 text-lg font-semibold text-gray-100">{@service_count}</div>
            </div>

            <div class="rounded-xl border border-gray-800 bg-gray-900/80 px-3 py-2">
              <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">Active</div>
              <div class="mt-2 truncate text-sm font-medium text-gray-200">{@active_service}</div>
            </div>
          </div>
        </div>

        <div class="grid gap-4 xl:grid-cols-[1.8fr,1fr]">
          <div class="space-y-4">
            <div class="grid gap-3 md:grid-cols-3">
              <div class="rounded-xl border border-emerald-500/20 bg-emerald-950/20 p-3">
                <div class="flex items-center justify-between">
                  <span class="text-[10px] uppercase tracking-[0.22em] text-emerald-300">
                    Sync bus
                  </span>
                  <span class="h-2 w-2 rounded-full bg-emerald-400"></span>
                </div>
                <div class="mt-3 text-lg font-semibold text-gray-100">Ready</div>
                <div class="mt-1 text-xs text-gray-400">
                  API probes, import sweep, delta writeback
                </div>
              </div>

              <div class="rounded-xl border border-sky-500/20 bg-sky-950/20 p-3">
                <div class="flex items-center justify-between">
                  <span class="text-[10px] uppercase tracking-[0.22em] text-sky-300">Workers</span>
                  <span class="h-2 w-2 rounded-full bg-sky-400"></span>
                </div>
                <div class="mt-3 text-lg font-semibold text-gray-100">Queued</div>
                <div class="mt-1 text-xs text-gray-400">Analyzer, CRF search, encoder handoff</div>
              </div>

              <div class="rounded-xl border border-amber-500/20 bg-amber-950/20 p-3">
                <div class="flex items-center justify-between">
                  <span class="text-[10px] uppercase tracking-[0.22em] text-amber-300">Surface</span>
                  <span class="h-2 w-2 rounded-full bg-amber-400"></span>
                </div>
                <div class="mt-3 text-lg font-semibold text-gray-100">Dense</div>
                <div class="mt-1 text-xs text-gray-400">
                  Cards, chips, queue hints, operator toast
                </div>
              </div>
            </div>

            <div class="rounded-2xl border border-gray-800 bg-gray-900/70">
              <div class="flex items-center justify-between border-b border-gray-800 px-4 py-3">
                <div>
                  <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">Runbook</div>
                  <div class="mt-1 text-sm font-semibold text-gray-100">
                    {if @repair_mode?, do: "Repair cycle", else: "First-run cycle"}
                  </div>
                </div>
                <span class="rounded-full border border-gray-700 bg-gray-800 px-2 py-1 text-[10px] uppercase tracking-[0.22em] text-gray-300">
                  4 steps
                </span>
              </div>

              <div class="grid gap-3 p-4 md:grid-cols-2">
                <div
                  :for={{step, index} <- Enum.with_index(@primary_steps, 1)}
                  class="rounded-xl border border-gray-800 bg-gray-950/70 p-3"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <div class="text-[10px] uppercase tracking-[0.22em] text-cyan-300">
                        Step {index}
                      </div>
                      <div class="mt-1 text-sm font-semibold text-gray-100">{step.title}</div>
                    </div>
                    <span class={step_chip_classes(step.state)}>{step.state}</span>
                  </div>
                  <p class="mt-2 text-xs leading-5 text-gray-400">{step.detail}</p>
                </div>
              </div>
            </div>

            <div class="rounded-2xl border border-gray-800 bg-gray-900/70 p-4">
              <div class="flex items-center justify-between">
                <div>
                  <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">
                    Operational checks
                  </div>
                  <div class="mt-1 text-sm font-semibold text-gray-100">
                    {if @repair_mode?, do: "Stabilize and resume", else: "Bring services online"}
                  </div>
                </div>
                <div class="text-[11px] uppercase tracking-[0.22em] text-gray-500">Tool view</div>
              </div>

              <div class="mt-4 grid gap-2">
                <div
                  :for={step <- @secondary_steps}
                  class="flex items-center justify-between rounded-xl border border-gray-800 bg-gray-950/70 px-3 py-2"
                >
                  <div class="min-w-0">
                    <div class="text-xs font-medium text-gray-200">{step.title}</div>
                    <div class="mt-1 text-[11px] text-gray-500">{step.detail}</div>
                  </div>
                  <span class={step_chip_classes(step.state)}>{step.state}</span>
                </div>
              </div>
            </div>
          </div>

          <div class="space-y-4">
            <div class="rounded-2xl border border-gray-800 bg-gray-900/70">
              <div class="flex items-center justify-between border-b border-gray-800 px-4 py-3">
                <div>
                  <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">
                    Service panel
                  </div>
                  <div class="mt-1 text-sm font-semibold text-gray-100">Attached endpoints</div>
                </div>
                <span class="rounded-full border border-gray-700 bg-gray-800 px-2 py-1 text-[10px] uppercase tracking-[0.22em] text-gray-300">
                  {@service_count} online
                </span>
              </div>

              <div class="space-y-2 p-4">
                <div
                  :for={service <- @services}
                  class={[
                    "rounded-xl border px-3 py-2",
                    if(service.active?,
                      do: "border-cyan-500/30 bg-cyan-950/20",
                      else: "border-gray-800 bg-gray-950/70"
                    )
                  ]}
                >
                  <div class="flex items-center justify-between gap-3">
                    <div class="min-w-0">
                      <div class="truncate text-sm font-medium text-gray-100">{service.name}</div>
                      <div class="mt-1 text-[11px] uppercase tracking-[0.18em] text-gray-500">
                        {service.role}
                      </div>
                    </div>
                    <span class={service_chip_classes(service.status, service.active?)}>
                      {service.status}
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <div class="rounded-2xl border border-gray-800 bg-gray-900/70 p-4">
              <div class="flex items-center justify-between">
                <div>
                  <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">
                    Toast preview
                  </div>
                  <div class="mt-1 text-sm font-semibold text-gray-100">Operator feedback</div>
                </div>
                <span class="rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2 py-1 text-[10px] uppercase tracking-[0.22em] text-emerald-300">
                  info
                </span>
              </div>

              <div class="mt-4 rounded-xl border border-emerald-500/20 bg-emerald-950/30 p-3 shadow-lg shadow-black/20">
                <div class="text-sm font-semibold text-emerald-200">{@toast_title}</div>
                <div class="mt-1 text-xs leading-5 text-emerald-100/80">{@toast_body}</div>
              </div>
            </div>

            <div class="rounded-2xl border border-gray-800 bg-gray-900/70 p-4">
              <div class="text-[10px] uppercase tracking-[0.22em] text-gray-500">Queue notes</div>
              <div class="mt-3 space-y-2">
                <div class="flex items-center justify-between rounded-xl border border-gray-800 bg-gray-950/70 px-3 py-2">
                  <span class="text-xs text-gray-300">Sync sweep</span>
                  <span class="rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2 py-1 text-[10px] uppercase tracking-[0.18em] text-emerald-300">
                    active
                  </span>
                </div>
                <div class="flex items-center justify-between rounded-xl border border-gray-800 bg-gray-950/70 px-3 py-2">
                  <span class="text-xs text-gray-300">Analyzer queue</span>
                  <span class="rounded-full border border-sky-500/20 bg-sky-500/10 px-2 py-1 text-[10px] uppercase tracking-[0.18em] text-sky-300">
                    waiting
                  </span>
                </div>
                <div class="flex items-center justify-between rounded-xl border border-gray-800 bg-gray-950/70 px-3 py-2">
                  <span class="text-xs text-gray-300">Encoder lane</span>
                  <span class="rounded-full border border-violet-500/20 bg-violet-500/10 px-2 py-1 text-[10px] uppercase tracking-[0.18em] text-violet-300">
                    staged
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp repair_mode?(mode), do: to_string(mode) == "repair"

  defp mode_label(mode) do
    if repair_mode?(mode), do: "Repair", else: "First run"
  end

  defp mode_chip_classes(mode) do
    if repair_mode?(mode) do
      "inline-flex items-center rounded-full border border-amber-500/30 bg-amber-500/10 px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.22em] text-amber-300"
    else
      "inline-flex items-center rounded-full border border-cyan-500/30 bg-cyan-500/10 px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.22em] text-cyan-300"
    end
  end

  defp step_chip_classes("ready"),
    do:
      "rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-emerald-300"

  defp step_chip_classes("check"),
    do:
      "rounded-full border border-amber-500/20 bg-amber-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-amber-300"

  defp step_chip_classes("repair"),
    do:
      "rounded-full border border-rose-500/20 bg-rose-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-rose-300"

  defp step_chip_classes(_state),
    do:
      "rounded-full border border-gray-700 bg-gray-800 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-gray-300"

  defp service_chip_classes("error", _active?),
    do:
      "rounded-full border border-rose-500/30 bg-rose-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-rose-300"

  defp service_chip_classes("needs repair", _active?),
    do:
      "rounded-full border border-amber-500/30 bg-amber-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-amber-300"

  defp service_chip_classes("missing", _active?),
    do:
      "rounded-full border border-cyan-500/30 bg-cyan-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-cyan-300"

  defp service_chip_classes("pending", _active?),
    do:
      "rounded-full border border-sky-500/30 bg-sky-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-sky-300"

  defp service_chip_classes(_status, true),
    do:
      "rounded-full border border-cyan-500/30 bg-cyan-500/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-cyan-300"

  defp service_chip_classes(_status, false),
    do:
      "rounded-full border border-gray-700 bg-gray-800 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-gray-400"

  defp normalize_services(services, active_service) do
    active_label = resolve_active_label(services, active_service)

    services
    |> Enum.with_index(1)
    |> Enum.map(fn {service, index} ->
      name = service_label(service)
      active? = name == active_label
      status = service_status(service, active?)

      %{
        name: name,
        role: service_role(service, index),
        status: status,
        active?: active?
      }
    end)
    |> case do
      [] ->
        [
          %{name: "Sonarr", role: "library source", status: "active", active?: true},
          %{name: "Radarr", role: "library source", status: "standby", active?: false}
        ]

      rows ->
        rows
    end
  end

  defp resolve_active_label(services, "Autoselect") do
    services |> Enum.find_value(&service_active_name/1) || "Autoselect"
  end

  defp resolve_active_label(services, active_service) do
    active_service || services |> Enum.find_value(&service_active_name/1) || "Autoselect"
  end

  defp service_active_name(service) when is_map(service) do
    if Map.get(service, :active) || Map.get(service, "active") do
      service_label(service)
    end
  end

  defp service_active_name(_service), do: nil

  defp service_label(nil), do: "Autoselect"
  defp service_label(service) when is_binary(service), do: service

  defp service_label(service) when is_atom(service),
    do: service |> Atom.to_string() |> String.capitalize()

  defp service_label(service) when is_map(service) do
    service[:name] || service["name"] || service[:label] || service["label"] ||
      service[:service_type] || service["service_type"] || "Service"
  end

  defp service_label(service), do: to_string(service)

  defp service_role(service, _index) when is_map(service) do
    service[:role] || service["role"] || service[:step_label] || service["step_label"] ||
      service[:service_type] || service["service_type"] || "service endpoint"
  end

  defp service_role(_service, 1), do: "primary endpoint"
  defp service_role(_service, _index), do: "service endpoint"

  defp service_status(service, true) when is_map(service) do
    format_status(service[:status] || service["status"] || "active")
  end

  defp service_status(service, false) when is_map(service) do
    format_status(service[:status] || service["status"] || "standby")
  end

  defp service_status(_service, true), do: "active"
  defp service_status(_service, false), do: "standby"

  defp format_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> format_status()

  defp format_status(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.downcase()
  end

  defp format_status(status), do: to_string(status)

  defp default_headline(true), do: "Repair the control plane and resume the queue"
  defp default_headline(false), do: "Wire services, index media, and launch the pipeline"

  defp default_subheadline(true) do
    "Re-run checks, isolate the failing service, and push the dashboard back to a steady state without losing operator context."
  end

  defp default_subheadline(false) do
    "Bring Sonarr and Radarr online, validate credentials, and expose the analyzer and encoder path with compact operational status."
  end

  defp default_toast_title(true), do: "Repair path armed"
  defp default_toast_title(false), do: "Setup path armed"

  defp default_toast_body(true) do
    "Credential probe passed. Replay sync and resume workers when the service panel turns green."
  end

  defp default_toast_body(false) do
    "Service handoff accepted. Initial sync can start as soon as both endpoints report ready."
  end

  defp primary_steps(true) do
    [
      %{
        title: "Probe credentials",
        detail: "Re-check URL, API key, and timeout path before any queue replay.",
        state: "check"
      },
      %{
        title: "Pin failing service",
        detail: "Route focus to the active endpoint and collapse noise from healthy peers.",
        state: "repair"
      },
      %{
        title: "Replay sync",
        detail: "Rebuild the import pass and verify fresh metadata enters the dashboard.",
        state: "check"
      },
      %{
        title: "Resume workers",
        detail: "Unlock analyzer and encoder lanes after health chips settle.",
        state: "ready"
      }
    ]
  end

  defp primary_steps(false) do
    [
      %{
        title: "Attach services",
        detail: "Register Sonarr and Radarr and mark one endpoint as active.",
        state: "ready"
      },
      %{
        title: "Validate access",
        detail: "Run credential probes before the first import sweep begins.",
        state: "check"
      },
      %{
        title: "Prime library sync",
        detail: "Pull media state into the local control plane with compact progress cards.",
        state: "check"
      },
      %{
        title: "Enable workers",
        detail: "Open analyzer, CRF search, and encoder lanes for normal operations.",
        state: "ready"
      }
    ]
  end

  defp secondary_steps(true) do
    [
      %{
        title: "Toast operator",
        detail: "Emit a short repair summary with the selected endpoint.",
        state: "repair"
      },
      %{
        title: "Preserve queue state",
        detail: "Avoid duplicate work while the dashboard rehydrates.",
        state: "check"
      },
      %{
        title: "Watch next sync",
        detail: "Keep the active service chip visible until the control loop is stable.",
        state: "ready"
      }
    ]
  end

  defp secondary_steps(false) do
    [
      %{
        title: "Seed dashboard cards",
        detail: "Show sync, workers, and queue posture immediately.",
        state: "ready"
      },
      %{
        title: "Expose first toast",
        detail: "Confirm the setup path with a short operator-facing notice.",
        state: "check"
      },
      %{
        title: "Hand off to operations",
        detail: "Leave a dense but readable surface for routine queue work.",
        state: "ready"
      }
    ]
  end
end
