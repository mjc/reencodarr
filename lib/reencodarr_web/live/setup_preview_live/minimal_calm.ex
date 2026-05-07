defmodule ReencodarrWeb.SetupPreviewLive.MinimalCalm do
  use Phoenix.Component

  attr :preview, :map, required: true

  def minimal_calm(assigns) do
    ~H"""
    <section class="space-y-6">
      <div class="rounded-[2rem] border border-gray-800 bg-gray-900/70 p-8 shadow-xl shadow-black/10">
        <div class="mx-auto max-w-4xl space-y-8">
          <div class="space-y-4 text-center">
            <p class="text-sm uppercase tracking-[0.24em] text-gray-500">Minimal calm</p>
            <h2 class="text-3xl font-semibold tracking-tight text-white">
              {@preview.headline}
            </h2>
            <p class="mx-auto max-w-2xl text-base leading-7 text-gray-300">
              {@preview.subheadline}
            </p>
          </div>

          <%= if @preview.mode == :repair do %>
            <div class="mx-auto max-w-2xl rounded-3xl border border-amber-400/30 bg-amber-400/8 p-5">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p class="text-sm font-semibold text-amber-100">{@preview.toast_title}</p>
                  <p class="mt-1 text-sm leading-6 text-amber-50/85">{@preview.toast_body}</p>
                </div>
                <button class="rounded-full bg-amber-200 px-4 py-2 text-sm font-medium text-amber-950">
                  Open repair flow
                </button>
              </div>
            </div>
          <% end %>

          <div class="grid gap-4 md:grid-cols-2">
            <%= for service <- @preview.services do %>
              <div class="rounded-3xl border border-gray-800 bg-gray-950/70 p-6">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-sm font-medium text-gray-400">{service.step_label}</p>
                    <h3 class="mt-1 text-xl font-semibold text-white">{service.name}</h3>
                  </div>
                  <span class={status_class(service.status)}>
                    {status_label(service.status)}
                  </span>
                </div>

                <p class="mt-6 text-sm font-medium text-gray-500">{service.url}</p>
                <p class="mt-3 text-sm leading-7 text-gray-300">{service.detail}</p>

                <div class="mt-8 flex items-center justify-between">
                  <div class="h-px flex-1 bg-gray-800"></div>
                  <button class="ml-4 rounded-full border border-gray-700 px-4 py-2 text-sm text-gray-200 transition-colors hover:border-gray-500 hover:text-white">
                    {service.cta}
                  </button>
                </div>
              </div>
            <% end %>
          </div>

          <div class="mx-auto flex max-w-xl items-center justify-center gap-3">
            <button class="rounded-full border border-gray-700 px-4 py-2 text-sm text-gray-300">
              Back
            </button>
            <button class="rounded-full bg-white px-5 py-2 text-sm font-medium text-gray-950">
              Continue
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp status_class(:healthy),
    do: "rounded-full bg-emerald-400/10 px-3 py-1 text-xs font-medium text-emerald-200"

  defp status_class(:error),
    do: "rounded-full bg-amber-400/10 px-3 py-1 text-xs font-medium text-amber-200"

  defp status_class(:missing),
    do: "rounded-full bg-cyan-400/10 px-3 py-1 text-xs font-medium text-cyan-200"

  defp status_class(_status),
    do: "rounded-full bg-gray-800 px-3 py-1 text-xs font-medium text-gray-300"

  defp status_label(:healthy), do: "Healthy"
  defp status_label(:error), do: "Repair"
  defp status_label(:missing), do: "Required"
  defp status_label(_status), do: "Next"
end
