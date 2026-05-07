defmodule ReencodarrWeb.SetupPreviewLive.DiagnosticFirst do
  use Phoenix.Component

  attr :preview, :map, required: true

  def diagnostic_first(assigns) do
    services = preview_value(assigns.preview, :services, [])
    active_service = resolve_active_service(assigns.preview, services)

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:active_service_card, active_service)
      |> assign(:repair_mode, preview_value(assigns.preview, :mode) == :repair)
      |> assign(:headline, preview_value(assigns.preview, :headline, ""))
      |> assign(:subheadline, preview_value(assigns.preview, :subheadline, ""))
      |> assign(:toast_title, preview_value(assigns.preview, :toast_title, ""))
      |> assign(:toast_body, preview_value(assigns.preview, :toast_body, ""))

    ~H"""
    <section class="space-y-6">
      <div class="overflow-hidden rounded-[2rem] border border-slate-800 bg-slate-950 shadow-2xl shadow-black/20">
        <div class="border-b border-slate-800 bg-gradient-to-br from-slate-900 via-slate-950 to-slate-950 px-8 py-8">
          <div class="flex flex-col gap-6 xl:flex-row xl:items-start xl:justify-between">
            <div class="max-w-3xl space-y-4">
              <div class="flex flex-wrap items-center gap-3">
                <span class="rounded-full border border-cyan-400/25 bg-cyan-400/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.22em] text-cyan-100">
                  Diagnostic-first setup
                </span>
                <span class="rounded-full border border-slate-700 bg-slate-900 px-3 py-1 text-xs font-medium text-slate-300">
                  Validation before save
                </span>
              </div>

              <div class="space-y-3">
                <h2 class="text-3xl font-semibold tracking-tight text-white sm:text-4xl">
                  {@headline}
                </h2>
                <p class="max-w-2xl text-base leading-7 text-slate-300">
                  {@subheadline}
                </p>
              </div>
            </div>

            <div class="w-full max-w-sm rounded-3xl border border-cyan-400/20 bg-cyan-400/10 p-5">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="text-sm font-semibold text-cyan-100">{@toast_title}</p>
                  <p class="mt-2 text-sm leading-6 text-cyan-50/85">{@toast_body}</p>
                </div>
                <span class={mode_badge_class(@repair_mode)}>
                  {if @repair_mode, do: "Repair", else: "First run"}
                </span>
              </div>
            </div>
          </div>

          <%= if @repair_mode do %>
            <div class="mt-6 rounded-3xl border border-amber-400/30 bg-amber-400/10 p-5">
              <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                <div class="space-y-2">
                  <p class="text-sm font-semibold uppercase tracking-[0.18em] text-amber-100">
                    Repair state active
                  </p>
                  <h3 class="text-xl font-semibold text-white">
                    Investigate the saved connection, keep the rest of the app available.
                  </h3>
                  <p class="max-w-3xl text-sm leading-6 text-amber-50/85">
                    The preview shifts from onboarding to focused remediation: show the failing endpoint,
                    explain why the check failed, and surface the next repair action without blocking healthy
                    services.
                  </p>
                </div>

                <div class="grid gap-2 text-sm text-amber-50/85 sm:min-w-72">
                  <div class="rounded-2xl border border-amber-300/20 bg-slate-950/40 px-4 py-3">
                    1. Re-test reachability and auth with the stored URL.
                  </div>
                  <div class="rounded-2xl border border-amber-300/20 bg-slate-950/40 px-4 py-3">
                    2. Show the exact failure reason before asking for edits.
                  </div>
                  <div class="rounded-2xl border border-amber-300/20 bg-slate-950/40 px-4 py-3">
                    3. Offer repair only for the broken service.
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <div class="grid gap-4 border-b border-slate-800 bg-slate-900/60 px-8 py-6 lg:grid-cols-3">
          <div class="rounded-3xl border border-slate-800 bg-slate-950/80 p-5">
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
              Validation detail
            </p>
            <p class="mt-3 text-lg font-semibold text-white">Config, auth, and response shape</p>
            <p class="mt-2 text-sm leading-6 text-slate-300">
              The layout makes pre-save checks explicit so operators can see what passed, what is still pending,
              and what data is missing.
            </p>
          </div>

          <div class="rounded-3xl border border-slate-800 bg-slate-950/80 p-5">
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
              Status readout
            </p>
            <p class="mt-3 text-lg font-semibold text-white">Reachability stays visible</p>
            <p class="mt-2 text-sm leading-6 text-slate-300">
              Each service card carries a direct endpoint summary so the active issue is obvious even before the
              detail panel opens.
            </p>
          </div>

          <div class="rounded-3xl border border-slate-800 bg-slate-950/80 p-5">
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
              Failure reasoning
            </p>
            <p class="mt-3 text-lg font-semibold text-white">Specific blockers, not generic errors</p>
            <p class="mt-2 text-sm leading-6 text-slate-300">
              The right-hand panel explains why a service cannot proceed and what action the user should take
              next.
            </p>
          </div>
        </div>

        <div class="grid gap-6 px-8 py-8 xl:grid-cols-[23rem_minmax(0,1fr)]">
          <div class="space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                  Service probes
                </p>
                <h3 class="mt-1 text-xl font-semibold text-white">Validation queue</h3>
              </div>
              <div class="rounded-full border border-slate-800 bg-slate-900 px-3 py-1 text-xs text-slate-400">
                {Enum.count(@services)} configured checks
              </div>
            </div>

            <div class="space-y-3">
              <%= for service <- @services do %>
                <div class={service_card_class(service, @active_service_card)}>
                  <div class="flex items-start justify-between gap-4">
                    <div>
                      <p class="text-xs font-medium uppercase tracking-[0.16em] text-slate-500">
                        {service_value(service, :step_label, "Validation")}
                      </p>
                      <h4 class="mt-1 text-lg font-semibold text-white">{service_name(service)}</h4>
                    </div>
                    <span class={status_chip_class(service_status(service))}>
                      {status_label(service_status(service))}
                    </span>
                  </div>

                  <div class="mt-4 space-y-3 text-sm text-slate-300">
                    <div>
                      <p class="text-xs font-semibold uppercase tracking-[0.14em] text-slate-500">
                        Endpoint
                      </p>
                      <p class="mt-1 font-medium text-slate-200">{service_endpoint(service)}</p>
                    </div>

                    <div class="flex flex-wrap gap-2">
                      <span class={probe_chip_class(service)}>
                        {service_reachability(service)}
                      </span>
                      <span class="rounded-full border border-slate-700 bg-slate-900 px-3 py-1 text-xs font-medium text-slate-300">
                        {service_validation_label(service)}
                      </span>
                    </div>

                    <p class="leading-6 text-slate-300">{service_summary(service)}</p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <div class={detail_panel_class(@active_service_card)}>
            <div class="flex flex-col gap-6 lg:flex-row lg:items-start lg:justify-between">
              <div class="space-y-3">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                  Active diagnostic
                </p>
                <div>
                  <h3 class="text-2xl font-semibold text-white">
                    {service_name(@active_service_card)}
                  </h3>
                  <p class="mt-2 max-w-2xl text-sm leading-7 text-slate-300">
                    {service_summary(@active_service_card)}
                  </p>
                </div>
              </div>

              <div class="flex flex-wrap gap-2">
                <span class={status_chip_class(service_status(@active_service_card))}>
                  {status_label(service_status(@active_service_card))}
                </span>
                <span class={probe_chip_class(@active_service_card)}>
                  {service_reachability(@active_service_card)}
                </span>
              </div>
            </div>

            <div class="mt-8 grid gap-4 lg:grid-cols-2">
              <div class="rounded-3xl border border-slate-800 bg-slate-950/70 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                  Endpoint reachability
                </p>
                <p class="mt-3 text-lg font-semibold text-white">
                  {service_endpoint(@active_service_card)}
                </p>
                <p class="mt-2 text-sm leading-6 text-slate-300">
                  {service_reachability_detail(@active_service_card)}
                </p>
              </div>

              <div class="rounded-3xl border border-slate-800 bg-slate-950/70 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                  Validation result
                </p>
                <p class="mt-3 text-lg font-semibold text-white">
                  {service_validation_label(@active_service_card)}
                </p>
                <p class="mt-2 text-sm leading-6 text-slate-300">
                  {service_validation_detail(@active_service_card)}
                </p>
              </div>
            </div>

            <div class="mt-4 rounded-3xl border border-rose-400/20 bg-rose-400/8 p-5">
              <p class="text-xs font-semibold uppercase tracking-[0.18em] text-rose-100">
                Failure reasoning
              </p>
              <p class="mt-3 text-lg font-semibold text-white">
                {service_reason(@active_service_card)}
              </p>
              <p class="mt-2 text-sm leading-6 text-rose-50/85">
                {service_reason_detail(@active_service_card)}
              </p>
            </div>

            <div class="mt-4 grid gap-4 lg:grid-cols-3">
              <div class="rounded-3xl border border-slate-800 bg-slate-950/70 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                  Credential check
                </p>
                <p class="mt-3 text-sm leading-6 text-slate-300">
                  {credential_status(@active_service_card)}
                </p>
              </div>

              <div class="rounded-3xl border border-slate-800 bg-slate-950/70 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                  Recovery path
                </p>
                <p class="mt-3 text-sm leading-6 text-slate-300">
                  {service_next_step(@active_service_card)}
                </p>
              </div>

              <div class="rounded-3xl border border-slate-800 bg-slate-950/70 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                  Operator signal
                </p>
                <p class="mt-3 text-sm leading-6 text-slate-300">
                  Keep the copy precise, keep the failing check visible, and avoid hiding the repair action.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp resolve_active_service(preview, [first | _] = services) do
    case preview_value(preview, :active_service) do
      nil ->
        first

      active when is_map(active) or is_list(active) ->
        active

      active ->
        Enum.find(services, first, fn service ->
          active in [
            service_id(service),
            service_name(service),
            service_value(service, :service_type)
          ]
        end)
    end
  end

  defp resolve_active_service(_preview, []), do: %{}

  defp preview_value(data, key, default \\ nil) do
    value(data, key, default)
  end

  defp service_value(data, key, default \\ nil) do
    value(data, key, default)
  end

  defp value(data, key, default) when is_map(data) do
    cond do
      Map.has_key?(data, key) -> Map.get(data, key)
      Map.has_key?(data, Atom.to_string(key)) -> Map.get(data, Atom.to_string(key))
      true -> default
    end
  end

  defp value(data, key, default) when is_list(data) do
    if Keyword.has_key?(data, key), do: Keyword.get(data, key), else: default
  end

  defp value(_data, _key, default), do: default

  defp service_id(service) do
    service_value(service, :id) || service_name(service) || service_endpoint(service)
  end

  defp service_name(service) do
    service_value(service, :name) || service_value(service, :service_type) || "Service"
  end

  defp service_status(service) do
    service_value(service, :status) || service_value(service, :state) || :pending
  end

  defp service_endpoint(service) do
    service_value(service, :endpoint) || service_value(service, :url) || "Endpoint not set"
  end

  defp service_summary(service) do
    service_value(service, :detail) ||
      service_value(service, :summary) ||
      "Run validation to inspect endpoint reachability, credentials, and response details."
  end

  defp service_validation_label(service) do
    service_value(service, :validation) ||
      service_value(service, :validation_status) ||
      case service_status(service) do
        :healthy -> "Validated"
        :error -> "Validation failed"
        :missing -> "Missing required values"
        :pending -> "Waiting for validation"
        other -> status_label(other)
      end
  end

  defp service_validation_detail(service) do
    service_value(service, :validation_detail) ||
      case service_status(service) do
        :healthy ->
          "The endpoint, auth, and response payload all match the expected service contract."

        :error ->
          "The request reached a blocking condition. Show the exact failing probe and keep the repair entry nearby."

        :missing ->
          "No live checks yet. The preview should explain which fields are still required before validation can run."

        :pending ->
          "This service stays queued until earlier setup steps provide enough data to run a probe."

        _ ->
          "Validation details should describe which checks ran and what evidence they returned."
      end
  end

  defp service_reachability(service) do
    service_value(service, :reachability) ||
      case service_value(service, :reachable) do
        true ->
          "Endpoint reachable"

        false ->
          "Endpoint unreachable"

        nil ->
          case service_status(service) do
            :healthy -> "Endpoint reachable"
            :error -> "Probe failed"
            :missing -> "No endpoint yet"
            _ -> "Awaiting probe"
          end
      end
  end

  defp service_reachability_detail(service) do
    service_value(service, :reachability_detail) ||
      case service_status(service) do
        :healthy ->
          "Recent checks completed successfully, so the panel can emphasize confirmation and readiness."

        :error ->
          "Reachability or auth failed. Keep timeout, DNS, and authorization clues visible instead of folding them into a generic banner."

        :missing ->
          "The user has not provided enough connection data to test the endpoint yet."

        _ ->
          "Show probe timing, host intent, and whether the request could be attempted at all."
      end
  end

  defp service_reason(service) do
    service_value(service, :reason) ||
      service_value(service, :failure_reason) ||
      service_value(service, :error) ||
      case service_status(service) do
        :healthy -> "No blocking failures detected"
        :error -> "The last validation request did not complete successfully"
        :missing -> "Required configuration is incomplete"
        _ -> "Validation is waiting for the next step"
      end
  end

  defp service_reason_detail(service) do
    service_value(service, :reason_detail) ||
      case service_status(service) do
        :healthy ->
          "Use this space to confirm why the service is considered safe to proceed, not only why failures happen."

        :error ->
          "Call out the failing URL, the returned behavior, and the likely operator fix so the repair path feels trustworthy."

        :missing ->
          "Explain which field is absent and what functionality stays blocked until it is supplied."

        _ ->
          "If nothing failed yet, explain what the preview is still waiting to inspect."
      end
  end

  defp credential_status(service) do
    service_value(service, :credential_status) ||
      case service_status(service) do
        :healthy ->
          "API key accepted and service identity confirmed."

        :error ->
          "Stored credentials should be re-tested and replaced only if the exact failure points to auth."

        :missing ->
          "API key and base URL are both required before credential validation can start."

        _ ->
          "Credential verification starts when the prior setup requirement is complete."
      end
  end

  defp service_next_step(service) do
    service_value(service, :next_step) ||
      service_value(service, :cta) ||
      case service_status(service) do
        :healthy -> "Continue with the remaining setup steps."
        :error -> "Open repair flow and re-run the failing probe."
        :missing -> "Add the missing URL and API key, then validate."
        _ -> "Finish the current service before moving on."
      end
  end

  defp service_card_class(service, active_service) do
    active = service_id(service) == service_id(active_service)

    [
      "rounded-3xl border p-5 transition-colors",
      if(active,
        do: "border-cyan-400/35 bg-cyan-400/10 shadow-lg shadow-cyan-950/20",
        else: "border-slate-800 bg-slate-900/70"
      )
    ]
  end

  defp detail_panel_class(service) do
    [
      "rounded-[2rem] border p-6",
      case service_status(service) do
        :healthy -> "border-emerald-400/20 bg-emerald-400/5"
        :error -> "border-rose-400/20 bg-rose-400/5"
        :missing -> "border-cyan-400/20 bg-cyan-400/5"
        _ -> "border-slate-800 bg-slate-900/70"
      end
    ]
  end

  defp mode_badge_class(true),
    do:
      "rounded-full border border-amber-300/30 bg-amber-300/15 px-3 py-1 text-xs font-semibold text-amber-100"

  defp mode_badge_class(false),
    do:
      "rounded-full border border-emerald-300/30 bg-emerald-300/15 px-3 py-1 text-xs font-semibold text-emerald-100"

  defp status_chip_class(status) do
    [
      "rounded-full px-3 py-1 text-xs font-semibold",
      case status do
        :healthy -> "border border-emerald-300/30 bg-emerald-300/15 text-emerald-100"
        :error -> "border border-rose-300/30 bg-rose-300/15 text-rose-100"
        :missing -> "border border-cyan-300/30 bg-cyan-300/15 text-cyan-100"
        _ -> "border border-slate-700 bg-slate-900 text-slate-300"
      end
    ]
  end

  defp probe_chip_class(service) do
    [
      "rounded-full px-3 py-1 text-xs font-medium",
      case service_status(service) do
        :healthy -> "border border-emerald-300/20 bg-emerald-300/10 text-emerald-100"
        :error -> "border border-amber-300/20 bg-amber-300/10 text-amber-100"
        :missing -> "border border-cyan-300/20 bg-cyan-300/10 text-cyan-100"
        _ -> "border border-slate-700 bg-slate-900 text-slate-300"
      end
    ]
  end

  defp status_label(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> status_label()
  end

  defp status_label("healthy"), do: "Validated"
  defp status_label("error"), do: "Needs repair"
  defp status_label("missing"), do: "Required"
  defp status_label("pending"), do: "Queued"

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp status_label(_status), do: "Pending"
end
