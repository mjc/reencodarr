defmodule ReencodarrWeb.SetupPreviewLive.GuidedOnboarding do
  use Phoenix.Component

  attr :preview, :map, required: true

  def guided_onboarding(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="mx-auto flex min-h-screen w-full max-w-7xl flex-col gap-10 px-6 py-10 lg:px-8">
        <div class="grid flex-1 gap-8 lg:grid-cols-[minmax(0,1.2fr)_24rem]">
          <section class="overflow-hidden rounded-3xl border border-gray-800 bg-gray-900/90 shadow-2xl shadow-black/30">
            <div class="border-b border-gray-800 bg-gradient-to-br from-amber-500/10 via-gray-900 to-sky-500/10 px-8 py-8 sm:px-10">
              <div class="flex flex-wrap items-center gap-3 text-xs font-semibold uppercase tracking-[0.28em] text-amber-300">
                <span class="rounded-full border border-amber-400/30 bg-amber-400/10 px-3 py-1">
                  Guided onboarding
                </span>
                <span class="rounded-full border border-sky-400/30 bg-sky-400/10 px-3 py-1 text-sky-200">
                  {mode_label(@preview.mode)}
                </span>
              </div>

              <div class="mt-6 max-w-3xl space-y-4">
                <h1 class="text-4xl font-semibold tracking-tight text-white sm:text-5xl">
                  {@preview.headline}
                </h1>
                <p class="max-w-2xl text-base leading-7 text-gray-300 sm:text-lg">
                  {@preview.subheadline}
                </p>
              </div>

              <div class="mt-8 grid gap-4 sm:grid-cols-3">
                <div class="rounded-2xl border border-gray-800 bg-gray-950/60 p-4">
                  <div class="text-xs font-semibold uppercase tracking-[0.2em] text-gray-500">
                    Current focus
                  </div>
                  <div class="mt-2 text-lg font-semibold text-white">{@preview.active_service}</div>
                  <p class="mt-1 text-sm text-gray-400">One clear step at a time keeps setup calm.</p>
                </div>
                <div class="rounded-2xl border border-gray-800 bg-gray-950/60 p-4">
                  <div class="text-xs font-semibold uppercase tracking-[0.2em] text-gray-500">
                    Services queued
                  </div>
                  <div class="mt-2 text-lg font-semibold text-white">
                    {length(@preview.services)}
                  </div>
                  <p class="mt-1 text-sm text-gray-400">
                    Every connection gets a simple status and next action.
                  </p>
                </div>
                <div class="rounded-2xl border border-gray-800 bg-gray-950/60 p-4">
                  <div class="text-xs font-semibold uppercase tracking-[0.2em] text-gray-500">
                    Finish line
                  </div>
                  <div class="mt-2 text-lg font-semibold text-white">Library ready</div>
                  <p class="mt-1 text-sm text-gray-400">
                    We will guide you to syncing, testing, and confidence.
                  </p>
                </div>
              </div>
            </div>

            <div class="px-8 py-8 sm:px-10">
              <div
                :if={@preview.mode == :repair}
                class="mb-8 rounded-2xl border border-amber-500/30 bg-amber-500/10 p-5"
              >
                <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div class="space-y-2">
                    <div class="text-xs font-semibold uppercase tracking-[0.24em] text-amber-200">
                      Repair helper
                    </div>
                    <h2 class="text-xl font-semibold text-white">
                      We found a setup that needs a quick tune-up.
                    </h2>
                    <p class="max-w-2xl text-sm leading-6 text-amber-50/80">
                      Your saved connections are still here. Review the highlighted step below, refresh the details,
                      and you will be back to a healthy setup without starting over.
                    </p>
                  </div>
                  <div class="rounded-2xl border border-amber-400/20 bg-gray-950/50 px-4 py-3 text-sm text-amber-100">
                    Friendly repair mode keeps the rest of your progress intact.
                  </div>
                </div>
              </div>

              <div class="space-y-4">
                <div class="flex items-center justify-between gap-4">
                  <div>
                    <h2 class="text-2xl font-semibold text-white">Step-by-step service checklist</h2>
                    <p class="mt-1 text-sm text-gray-400">
                      Start with the highlighted service, then follow the next actions in order.
                    </p>
                  </div>
                  <div class="hidden rounded-full border border-gray-800 bg-gray-950/80 px-4 py-2 text-xs font-semibold uppercase tracking-[0.22em] text-gray-400 sm:block">
                    Warm, guided preview
                  </div>
                </div>

                <div class="space-y-4">
                  <div
                    :for={{service, index} <- Enum.with_index(@preview.services, 1)}
                    class={service_card_classes(service, @preview.active_service)}
                  >
                    <div class="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
                      <div class="flex gap-4">
                        <div class={step_badge_classes(service, @preview.active_service)}>
                          {index}
                        </div>

                        <div class="space-y-3">
                          <div class="flex flex-wrap items-center gap-3">
                            <h3 class="text-xl font-semibold text-white">{service.name}</h3>
                            <span class={status_badge_classes(service.status)}>
                              {status_label(service.status)}
                            </span>
                            <span
                              :if={service.name == @preview.active_service}
                              class="rounded-full border border-amber-400/30 bg-amber-400/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.2em] text-amber-200"
                            >
                              Active now
                            </span>
                          </div>

                          <div class="space-y-1">
                            <div class="text-sm font-semibold uppercase tracking-[0.18em] text-gray-500">
                              {service.step_label}
                            </div>
                            <p class="max-w-2xl text-sm leading-6 text-gray-300">{service.detail}</p>
                          </div>

                          <div class="flex flex-wrap items-center gap-3 text-sm text-gray-400">
                            <span class="rounded-full border border-gray-800 bg-gray-950/80 px-3 py-1 font-mono text-xs text-sky-200">
                              {service.url}
                            </span>
                            <span class="text-gray-500">Next:</span>
                            <span class="font-medium text-white">{service.cta}</span>
                          </div>
                        </div>
                      </div>

                      <div class="rounded-2xl border border-gray-800 bg-gray-950/70 px-4 py-3 text-sm text-gray-300 lg:w-60">
                        <div class="text-xs font-semibold uppercase tracking-[0.18em] text-gray-500">
                          Guidance
                        </div>
                        <p class="mt-2 leading-6">
                          {service_guidance(service, @preview.active_service)}
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <aside class="flex flex-col gap-6">
            <section class="rounded-3xl border border-gray-800 bg-gray-900/90 p-6 shadow-xl shadow-black/20">
              <div class="text-xs font-semibold uppercase tracking-[0.24em] text-sky-300">
                Preview toast
              </div>
              <div class="mt-4 rounded-2xl border border-sky-400/20 bg-sky-500/10 p-4">
                <div class="text-sm font-semibold text-white">{@preview.toast_title}</div>
                <p class="mt-2 text-sm leading-6 text-sky-50/85">{@preview.toast_body}</p>
              </div>
              <p class="mt-4 text-sm leading-6 text-gray-400">
                Use this friendly confirmation point to reassure people that setup is moving forward.
              </p>
            </section>

            <section class="rounded-3xl border border-gray-800 bg-gray-900/90 p-6 shadow-xl shadow-black/20">
              <div class="text-xs font-semibold uppercase tracking-[0.24em] text-amber-300">
                What this variant feels like
              </div>
              <ul class="mt-4 space-y-3 text-sm leading-6 text-gray-300">
                <li class="rounded-2xl border border-gray-800 bg-gray-950/70 px-4 py-3">
                  Soft encouragement instead of terse setup copy.
                </li>
                <li class="rounded-2xl border border-gray-800 bg-gray-950/70 px-4 py-3">
                  Clear progress framing so each service feels manageable.
                </li>
                <li class="rounded-2xl border border-gray-800 bg-gray-950/70 px-4 py-3">
                  Repair mode keeps the message calm while pointing to the exact fix.
                </li>
              </ul>
            </section>

            <section class="rounded-3xl border border-gray-800 bg-gradient-to-br from-gray-900 via-gray-900 to-amber-500/10 p-6 shadow-xl shadow-black/20">
              <div class="text-xs font-semibold uppercase tracking-[0.24em] text-gray-400">
                Guided path
              </div>
              <div class="mt-4 space-y-4">
                <div
                  :for={service <- @preview.services}
                  class="flex items-center gap-3 rounded-2xl border border-gray-800 bg-gray-950/70 px-4 py-3"
                >
                  <div class={
                    mini_status_dot_classes(service.status, service.name == @preview.active_service)
                  }>
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="truncate text-sm font-semibold text-white">{service.name}</div>
                    <div class="truncate text-xs text-gray-500">{service.step_label}</div>
                  </div>
                </div>
              </div>
            </section>
          </aside>
        </div>
      </div>
    </div>
    """
  end

  defp mode_label(:repair), do: "Repair mode"
  defp mode_label(:first_run), do: "First run"

  defp status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp service_card_classes(service, active_service) do
    active? = service.name == active_service

    [
      "rounded-3xl border p-6 transition-colors",
      if(active?,
        do: "border-amber-400/40 bg-amber-500/10 shadow-lg shadow-amber-500/5",
        else: "border-gray-800 bg-gray-950/70"
      )
    ]
  end

  defp step_badge_classes(service, active_service) do
    active? = service.name == active_service

    [
      "flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl border text-base font-semibold",
      if(active?,
        do: "border-amber-300/40 bg-amber-400/15 text-amber-100",
        else: "border-gray-700 bg-gray-900 text-gray-300"
      )
    ]
  end

  defp status_badge_classes(status) when status in [:connected, :ready, :healthy, :complete] do
    "rounded-full border border-emerald-400/30 bg-emerald-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-emerald-200"
  end

  defp status_badge_classes(status) when status in [:attention, :repair, :warning, :pending] do
    "rounded-full border border-amber-400/30 bg-amber-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-amber-200"
  end

  defp status_badge_classes(_status) do
    "rounded-full border border-sky-400/30 bg-sky-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-sky-200"
  end

  defp service_guidance(service, active_service) do
    cond do
      service.name == active_service ->
        "This is the step to focus on next. Confirm the details, then continue once the connection looks right."

      service.status in [:connected, :ready, :healthy, :complete] ->
        "This step looks settled, so you can leave it as-is unless you want to review the saved URL."

      true ->
        "Keep this one nearby. When the active step is done, this card becomes the next guided action."
    end
  end

  defp mini_status_dot_classes(status, true)
       when status in [:connected, :ready, :healthy, :complete] do
    "h-3 w-3 rounded-full bg-emerald-400 shadow-[0_0_0_4px_rgba(52,211,153,0.12)]"
  end

  defp mini_status_dot_classes(_status, true) do
    "h-3 w-3 rounded-full bg-amber-300 shadow-[0_0_0_4px_rgba(252,211,77,0.18)]"
  end

  defp mini_status_dot_classes(status, false)
       when status in [:connected, :ready, :healthy, :complete] do
    "h-3 w-3 rounded-full bg-emerald-400"
  end

  defp mini_status_dot_classes(status, false)
       when status in [:attention, :repair, :warning, :pending] do
    "h-3 w-3 rounded-full bg-amber-300"
  end

  defp mini_status_dot_classes(_status, false) do
    "h-3 w-3 rounded-full bg-sky-300"
  end
end
