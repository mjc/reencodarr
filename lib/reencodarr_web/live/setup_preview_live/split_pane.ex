defmodule ReencodarrWeb.SetupPreviewLive.SplitPane do
  use Phoenix.Component

  attr :preview, :map, required: true

  def split_pane(assigns) do
    active_service = active_service(assigns.preview)

    assigns =
      assigns
      |> assign(:active_service_card, active_service)
      |> assign(:completed_steps, completed_steps(assigns.preview.services))
      |> assign(:progress_width, progress_width(assigns.preview.services))

    ~H"""
    <section class="rounded-[2rem] border border-gray-800 bg-gray-950/80 p-4 shadow-2xl shadow-black/20 sm:p-6">
      <div class="grid gap-6 xl:grid-cols-[minmax(0,0.92fr)_minmax(0,1.08fr)]">
        <aside class="overflow-hidden rounded-[1.75rem] border border-gray-800 bg-gray-900/90">
          <div class="border-b border-gray-800 bg-gradient-to-br from-cyan-500/10 via-gray-900 to-indigo-500/10 px-6 py-6 sm:px-8">
            <div class="flex flex-wrap items-center gap-3 text-xs font-semibold uppercase tracking-[0.22em]">
              <span class="rounded-full border border-cyan-400/30 bg-cyan-400/10 px-3 py-1 text-cyan-200">
                Split pane
              </span>
              <span class={mode_badge_classes(@preview.mode)}>
                {mode_label(@preview.mode)}
              </span>
            </div>

            <div class="mt-6 space-y-3">
              <h2 class="text-3xl font-semibold tracking-tight text-white sm:text-4xl">
                {@preview.headline}
              </h2>
              <p class="max-w-2xl text-sm leading-7 text-gray-300 sm:text-base">
                {@preview.subheadline}
              </p>
            </div>

            <div class="mt-6 rounded-3xl border border-gray-800 bg-gray-950/70 p-5">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <div class="text-xs font-semibold uppercase tracking-[0.2em] text-gray-500">
                    Setup progress
                  </div>
                  <div class="mt-2 text-2xl font-semibold text-white">
                    {@completed_steps} of {length(@preview.services)} services ready
                  </div>
                </div>
                <div class="rounded-2xl border border-gray-800 bg-gray-900 px-4 py-3 text-right">
                  <div class="text-xs uppercase tracking-[0.18em] text-gray-500">Active</div>
                  <div class="mt-1 text-sm font-semibold text-white">{@preview.active_service}</div>
                </div>
              </div>

              <div class="mt-4 h-2 rounded-full bg-gray-800">
                <div
                  class="h-2 rounded-full bg-gradient-to-r from-cyan-400 to-indigo-400"
                  style={"width: #{@progress_width}%"}
                >
                </div>
              </div>

              <p class="mt-3 text-sm text-gray-400">
                Left pane keeps service order, status, and next action visible while the right pane stays focused on the current form.
              </p>
            </div>
          </div>

          <div class="space-y-4 px-6 py-6 sm:px-8">
            <div class={selection_banner_classes(@preview.mode)}>
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div class="space-y-2">
                  <div class="text-xs font-semibold uppercase tracking-[0.22em]">
                    {banner_eyebrow(@preview.mode)}
                  </div>
                  <h3 class="text-lg font-semibold text-white">{banner_title(@preview.mode)}</h3>
                  <p class="text-sm leading-6 text-inherit/80">{banner_body(@preview)}</p>
                </div>
                <div class="rounded-2xl border border-current/15 bg-gray-950/60 px-4 py-3 text-sm text-white">
                  {@preview.toast_title}
                </div>
              </div>
            </div>

            <div class="space-y-3">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <h3 class="text-lg font-semibold text-white">Service selector</h3>
                  <p class="mt-1 text-sm text-gray-400">
                    Progress lives here so the active form never hides what comes next.
                  </p>
                </div>
                <div class="hidden rounded-full border border-gray-800 bg-gray-950/80 px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-gray-500 sm:block">
                  Select -> validate -> continue
                </div>
              </div>

              <div class="space-y-3">
                <div
                  :for={{service, index} <- Enum.with_index(@preview.services, 1)}
                  class={service_row_classes(service, @preview.active_service)}
                >
                  <div class="flex items-start gap-4">
                    <div class={step_index_classes(service, @preview.active_service)}>
                      {index}
                    </div>

                    <div class="min-w-0 flex-1 space-y-3">
                      <div class="flex flex-wrap items-center gap-3">
                        <h4 class="text-lg font-semibold text-white">{service.name}</h4>
                        <span class={status_badge_classes(service.status)}>
                          {status_label(service.status)}
                        </span>
                        <span
                          :if={service.name == @preview.active_service}
                          class="rounded-full border border-cyan-400/30 bg-cyan-400/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-cyan-200"
                        >
                          Open in form
                        </span>
                      </div>

                      <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_12rem]">
                        <div class="space-y-2">
                          <div class="text-xs font-semibold uppercase tracking-[0.18em] text-gray-500">
                            {service.step_label}
                          </div>
                          <p class="text-sm leading-6 text-gray-300">{service.detail}</p>
                          <div class="font-mono text-xs text-gray-500">{service.url}</div>
                        </div>

                        <div class="rounded-2xl border border-gray-800 bg-gray-950/80 px-4 py-3">
                          <div class="text-xs font-semibold uppercase tracking-[0.18em] text-gray-500">
                            Next action
                          </div>
                          <div class="mt-2 text-sm font-medium text-white">{service.cta}</div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </aside>

        <section class="overflow-hidden rounded-[1.75rem] border border-gray-800 bg-gray-900/95">
          <div class="border-b border-gray-800 px-6 py-6 sm:px-8">
            <div class="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
              <div class="space-y-3">
                <div class="text-xs font-semibold uppercase tracking-[0.22em] text-indigo-300">
                  Active service workspace
                </div>
                <h3 class="text-2xl font-semibold text-white">
                  {@active_service_card.name} configuration and validation
                </h3>
                <p class="max-w-2xl text-sm leading-7 text-gray-300">
                  Right pane is reserved for the live form, validation feedback, and the specific recovery state for the selected service.
                </p>
              </div>

              <div class="grid gap-3 sm:grid-cols-2">
                <div class="rounded-2xl border border-gray-800 bg-gray-950/80 px-4 py-3">
                  <div class="text-xs uppercase tracking-[0.18em] text-gray-500">Selected status</div>
                  <div class="mt-2 text-sm font-semibold text-white">
                    {status_label(@active_service_card.status)}
                  </div>
                </div>
                <div class="rounded-2xl border border-gray-800 bg-gray-950/80 px-4 py-3">
                  <div class="text-xs uppercase tracking-[0.18em] text-gray-500">Focused CTA</div>
                  <div class="mt-2 text-sm font-semibold text-white">{@active_service_card.cta}</div>
                </div>
              </div>
            </div>
          </div>

          <div class="grid gap-6 px-6 py-6 sm:px-8 lg:grid-cols-[minmax(0,1.2fr)_18rem]">
            <div class="space-y-6">
              <div class={workspace_notice_classes(@preview.mode)}>
                <div class="text-xs font-semibold uppercase tracking-[0.2em]">
                  {workspace_notice_eyebrow(@preview.mode)}
                </div>
                <h4 class="mt-2 text-xl font-semibold text-white">
                  {workspace_notice_title(@preview)}
                </h4>
                <p class="mt-3 text-sm leading-6 text-inherit/80">
                  {workspace_notice_body(@preview, @active_service_card)}
                </p>
              </div>

              <div class="rounded-3xl border border-gray-800 bg-gray-950/70 p-5">
                <div class="flex items-center justify-between gap-4">
                  <div>
                    <div class="text-xs font-semibold uppercase tracking-[0.18em] text-gray-500">
                      Service form
                    </div>
                    <div class="mt-2 text-lg font-semibold text-white">
                      {@active_service_card.name}
                    </div>
                  </div>
                  <div class="rounded-full border border-gray-800 bg-gray-900 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-gray-400">
                    Inline validation
                  </div>
                </div>

                <div class="mt-5 grid gap-4">
                  <label class="space-y-2">
                    <span class="text-sm font-medium text-gray-200">Base URL</span>
                    <div class={input_shell_classes(@active_service_card.status)}>
                      <span class="text-sm text-white">
                        {field_url(@active_service_card, @preview.mode)}
                      </span>
                    </div>
                    <span class="text-xs text-gray-500">
                      {url_hint(@preview.mode, @active_service_card)}
                    </span>
                  </label>

                  <label class="space-y-2">
                    <span class="text-sm font-medium text-gray-200">API key</span>
                    <div class="rounded-2xl border border-gray-800 bg-gray-900 px-4 py-3">
                      <div class="flex items-center justify-between gap-4">
                        <span class="font-mono text-sm text-gray-300">
                          {api_key_mask(@preview.mode)}
                        </span>
                        <span class="rounded-full border border-gray-700 px-3 py-1 text-xs uppercase tracking-[0.18em] text-gray-400">
                          {api_key_state(@preview.mode)}
                        </span>
                      </div>
                    </div>
                    <span class="text-xs text-gray-500">{api_key_hint(@preview.mode)}</span>
                  </label>
                </div>

                <div class="mt-6 grid gap-4 md:grid-cols-2">
                  <div class="rounded-2xl border border-gray-800 bg-gray-900/80 p-4">
                    <div class="text-xs font-semibold uppercase tracking-[0.18em] text-gray-500">
                      Validation checks
                    </div>
                    <ul class="mt-3 space-y-3 text-sm text-gray-300">
                      <li class="flex items-start gap-3">
                        <span class={check_dot_classes(@preview.mode, :endpoint)}></span>
                        <span>{endpoint_check(@preview.mode, @active_service_card)}</span>
                      </li>
                      <li class="flex items-start gap-3">
                        <span class={check_dot_classes(@preview.mode, :auth)}></span>
                        <span>{auth_check(@preview.mode, @active_service_card)}</span>
                      </li>
                      <li class="flex items-start gap-3">
                        <span class={check_dot_classes(@preview.mode, :webhook)}></span>
                        <span>{webhook_check(@preview.mode, @active_service_card)}</span>
                      </li>
                    </ul>
                  </div>

                  <div class="rounded-2xl border border-gray-800 bg-gray-900/80 p-4">
                    <div class="text-xs font-semibold uppercase tracking-[0.18em] text-gray-500">
                      Operator guidance
                    </div>
                    <p class="mt-3 text-sm leading-6 text-gray-300">
                      {operator_guidance(@preview.mode, @active_service_card)}
                    </p>
                    <div class="mt-4 rounded-2xl border border-gray-800 bg-gray-950/80 px-4 py-3 text-sm text-white">
                      {cta_copy(@preview.mode, @active_service_card)}
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <aside class="space-y-4">
              <div class="rounded-3xl border border-gray-800 bg-gray-950/70 p-5">
                <div class="text-xs font-semibold uppercase tracking-[0.2em] text-gray-500">
                  Validation state
                </div>
                <div class="mt-4 space-y-3">
                  <div class={state_card_classes(@preview.mode, :form)}>
                    <div class="text-sm font-semibold text-white">Form edited</div>
                    <p class="mt-1 text-xs leading-5 text-inherit/80">
                      {form_state_copy(@preview.mode)}
                    </p>
                  </div>
                  <div class={state_card_classes(@preview.mode, :test)}>
                    <div class="text-sm font-semibold text-white">Connection test</div>
                    <p class="mt-1 text-xs leading-5 text-inherit/80">
                      {test_state_copy(@preview.mode)}
                    </p>
                  </div>
                  <div class={state_card_classes(@preview.mode, :finish)}>
                    <div class="text-sm font-semibold text-white">Ready to continue</div>
                    <p class="mt-1 text-xs leading-5 text-inherit/80">
                      {finish_state_copy(@preview.mode)}
                    </p>
                  </div>
                </div>
              </div>

              <div class="rounded-3xl border border-gray-800 bg-gray-950/70 p-5">
                <div class="text-xs font-semibold uppercase tracking-[0.2em] text-gray-500">
                  Repair toast
                </div>
                <div class="mt-4 rounded-2xl border border-gray-800 bg-gray-900/80 p-4">
                  <div class="text-sm font-semibold text-white">{@preview.toast_title}</div>
                  <p class="mt-2 text-sm leading-6 text-gray-300">{@preview.toast_body}</p>
                </div>
              </div>
            </aside>
          </div>
        </section>
      </div>
    </section>
    """
  end

  defp active_service(%{active_service: name, services: services}) do
    Enum.find(services, List.first(services), fn service -> service.name == name end)
  end

  defp completed_steps(services) do
    Enum.count(services, fn service ->
      service.status in [:healthy, :connected, :ready, :complete]
    end)
  end

  defp progress_width([]), do: 0
  defp progress_width(services), do: round(completed_steps(services) / length(services) * 100)

  defp mode_label(:repair), do: "Repair mode"
  defp mode_label(:first_run), do: "First run"

  defp mode_badge_classes(:repair) do
    "rounded-full border border-amber-400/30 bg-amber-400/10 px-3 py-1 text-amber-200"
  end

  defp mode_badge_classes(:first_run) do
    "rounded-full border border-emerald-400/30 bg-emerald-400/10 px-3 py-1 text-emerald-200"
  end

  defp selection_banner_classes(:repair) do
    "rounded-3xl border border-amber-400/30 bg-amber-400/10 p-5 text-amber-100"
  end

  defp selection_banner_classes(:first_run) do
    "rounded-3xl border border-cyan-400/30 bg-cyan-400/10 p-5 text-cyan-100"
  end

  defp banner_eyebrow(:repair), do: "Repair entry"
  defp banner_eyebrow(:first_run), do: "Blocking setup"

  defp banner_title(:repair),
    do: "The selector keeps the broken service visible while the app stays usable."

  defp banner_title(:first_run),
    do: "The selector works like a checklist so first-time setup feels finite."

  defp banner_body(%{mode: :repair, toast_body: toast_body}), do: toast_body

  defp banner_body(%{mode: :first_run}) do
    "People land on the first missing service, see what unlocks next, and understand why setup must happen now."
  end

  defp service_row_classes(service, active_service) do
    active? = service.name == active_service

    [
      "rounded-3xl border p-5 transition-colors",
      if(active?,
        do: "border-cyan-400/40 bg-cyan-500/8 shadow-lg shadow-cyan-500/5",
        else: "border-gray-800 bg-gray-950/70"
      )
    ]
  end

  defp step_index_classes(service, active_service) do
    active? = service.name == active_service

    [
      "flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl border text-sm font-semibold",
      if(active?,
        do: "border-cyan-300/40 bg-cyan-400/15 text-cyan-100",
        else: "border-gray-700 bg-gray-900 text-gray-300"
      )
    ]
  end

  defp status_badge_classes(status) when status in [:healthy, :connected, :ready, :complete] do
    "rounded-full border border-emerald-400/30 bg-emerald-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-emerald-200"
  end

  defp status_badge_classes(status) when status in [:error, :repair, :attention, :warning] do
    "rounded-full border border-amber-400/30 bg-amber-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-amber-200"
  end

  defp status_badge_classes(:missing) do
    "rounded-full border border-cyan-400/30 bg-cyan-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-cyan-200"
  end

  defp status_badge_classes(_status) do
    "rounded-full border border-gray-700 bg-gray-800 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-gray-300"
  end

  defp status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp workspace_notice_classes(:repair) do
    "rounded-3xl border border-amber-400/30 bg-amber-400/10 p-5 text-amber-100"
  end

  defp workspace_notice_classes(:first_run) do
    "rounded-3xl border border-indigo-400/30 bg-indigo-500/10 p-5 text-indigo-100"
  end

  defp workspace_notice_eyebrow(:repair), do: "Repair state"
  defp workspace_notice_eyebrow(:first_run), do: "First-run form"

  defp workspace_notice_title(%{mode: :repair}) do
    "Show the saved connection, the failing check, and the repair path together."
  end

  defp workspace_notice_title(%{mode: :first_run}) do
    "Use the form area to build confidence before unlocking the next service."
  end

  defp workspace_notice_body(%{mode: :repair}, service) do
    "#{service.name} stays selected so the operator can fix the broken endpoint without hunting through settings."
  end

  defp workspace_notice_body(%{mode: :first_run}, service) do
    "#{service.name} is the only required decision in view, which keeps the new-user journey focused and sequential."
  end

  defp field_url(service, :repair), do: service.url

  defp field_url(service, :first_run),
    do: "http://#{String.downcase(service.name)}.lan:#{default_port(service.name)}"

  defp default_port("Sonarr"), do: "8989"
  defp default_port("Radarr"), do: "7878"
  defp default_port(_name), do: "0000"

  defp url_hint(:repair, _service),
    do: "Existing value is shown so the failing connection can be repaired in place."

  defp url_hint(:first_run, _service),
    do: "Placeholder mirrors the expected Arr base URL for a first-time setup."

  defp api_key_mask(:repair), do: "rdr-12ab-xxxx-rotated"
  defp api_key_mask(:first_run), do: "Paste API key from the Arr web UI"

  defp api_key_state(:repair), do: "Needs retest"
  defp api_key_state(:first_run), do: "Required"

  defp api_key_hint(:repair),
    do: "Keep the existing key if it still works, or replace it after a rotation."

  defp api_key_hint(:first_run),
    do: "Nothing else should continue until the key is present and the test passes."

  defp input_shell_classes(status) when status in [:error, :repair, :attention, :warning] do
    "rounded-2xl border border-amber-400/30 bg-amber-400/8 px-4 py-3"
  end

  defp input_shell_classes(:missing) do
    "rounded-2xl border border-cyan-400/30 bg-cyan-400/8 px-4 py-3"
  end

  defp input_shell_classes(_status) do
    "rounded-2xl border border-gray-800 bg-gray-900 px-4 py-3"
  end

  defp check_dot_classes(:repair, kind) when kind in [:endpoint, :auth] do
    "mt-1 h-2.5 w-2.5 rounded-full bg-amber-300"
  end

  defp check_dot_classes(:repair, :webhook), do: "mt-1 h-2.5 w-2.5 rounded-full bg-gray-600"

  defp check_dot_classes(:first_run, :endpoint), do: "mt-1 h-2.5 w-2.5 rounded-full bg-cyan-300"
  defp check_dot_classes(:first_run, :auth), do: "mt-1 h-2.5 w-2.5 rounded-full bg-cyan-300"
  defp check_dot_classes(:first_run, :webhook), do: "mt-1 h-2.5 w-2.5 rounded-full bg-gray-600"

  defp endpoint_check(:repair, service) do
    "Last probe to #{service.url} timed out, so the host or port should be verified first."
  end

  defp endpoint_check(:first_run, service) do
    "Confirm the #{service.name} base URL before any deeper checks run."
  end

  defp auth_check(:repair, _service) do
    "Re-test with the saved API key and surface a clear error if the key was rotated."
  end

  defp auth_check(:first_run, _service) do
    "Validate that the pasted API key can reach system status and queue endpoints."
  end

  defp webhook_check(:repair, _service) do
    "Webhook repair waits until the primary connection is healthy again."
  end

  defp webhook_check(:first_run, _service) do
    "Webhook guidance appears after the connection test succeeds."
  end

  defp operator_guidance(:repair, service) do
    "Show the last known good value for #{service.name}, explain the failing health check, and keep the recovery CTA above the fold."
  end

  defp operator_guidance(:first_run, service) do
    "Let the operator finish #{service.name} end-to-end before exposing the next service, so setup momentum stays high."
  end

  defp cta_copy(:repair, service), do: "Primary action: #{service.cta}"
  defp cta_copy(:first_run, _service), do: "Primary action: Validate and continue"

  defp state_card_classes(:repair, :form) do
    "rounded-2xl border border-amber-400/30 bg-amber-400/10 p-4 text-amber-100"
  end

  defp state_card_classes(:repair, :test) do
    "rounded-2xl border border-amber-400/30 bg-gray-900 p-4 text-amber-100"
  end

  defp state_card_classes(:repair, :finish) do
    "rounded-2xl border border-gray-800 bg-gray-900 p-4 text-gray-300"
  end

  defp state_card_classes(:first_run, :form) do
    "rounded-2xl border border-cyan-400/30 bg-cyan-400/10 p-4 text-cyan-100"
  end

  defp state_card_classes(:first_run, :test) do
    "rounded-2xl border border-gray-800 bg-gray-900 p-4 text-gray-300"
  end

  defp state_card_classes(:first_run, :finish) do
    "rounded-2xl border border-gray-800 bg-gray-900 p-4 text-gray-300"
  end

  defp form_state_copy(:repair),
    do: "Saved values load immediately so the repair flow starts from known context."

  defp form_state_copy(:first_run),
    do: "Empty fields and clear labels support a clean first pass."

  defp test_state_copy(:repair), do: "Re-run connection tests after editing the URL or API key."

  defp test_state_copy(:first_run),
    do: "Connection checks stay inline and unlock the next step on success."

  defp finish_state_copy(:repair),
    do: "Once healthy, the service quietly returns to the normal dashboard state."

  defp finish_state_copy(:first_run),
    do: "Finishing this form advances the selector to the next required service."
end
