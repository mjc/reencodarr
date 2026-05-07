defmodule ReencodarrWeb.SetupPreviewLive do
  use ReencodarrWeb, :live_view

  import ReencodarrWeb.SetupPreviewLive.DashboardNative, only: [dashboard_native: 1]
  import ReencodarrWeb.SetupPreviewLive.DiagnosticFirst, only: [diagnostic_first: 1]
  import ReencodarrWeb.SetupPreviewLive.GuidedOnboarding, only: [guided_onboarding: 1]
  import ReencodarrWeb.SetupPreviewLive.MinimalCalm, only: [minimal_calm: 1]
  import ReencodarrWeb.SetupPreviewLive.SplitPane, only: [split_pane: 1]

  @variants [
    {"guided", "Guided onboarding"},
    {"dashboard", "Dashboard-native"},
    {"diagnostic", "Diagnostic-first"},
    {"split", "Split-pane"},
    {"minimal", "Minimal calm"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Setup Preview",
       variants: @variants,
       variant: "guided",
       mode: :first_run,
       preview: build_preview(:first_run)
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    variant = normalize_variant(params["variant"])
    mode = normalize_mode(params["mode"])

    {:noreply,
     assign(socket,
       variants: @variants,
       variant: variant,
       mode: mode,
       preview: build_preview(mode)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <div class="mb-8 rounded-3xl border border-gray-800 bg-gray-900/90 p-6 shadow-2xl shadow-black/20">
          <div class="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
            <div class="max-w-3xl space-y-3">
              <p class="text-sm font-semibold uppercase tracking-[0.2em] text-cyan-300">
                Setup preview fleet
              </p>
              <h1 class="text-3xl font-bold tracking-tight text-white sm:text-4xl">
                Compare setup looks before we commit
              </h1>
              <p class="text-base leading-7 text-gray-300">
                This preview route shows five visual directions for the chosen hybrid UX:
                a blocking first-run wizard plus a focused repair flow entered from a toast.
              </p>
            </div>

            <div class="rounded-2xl border border-cyan-500/30 bg-cyan-500/10 px-4 py-3 text-sm text-cyan-100">
              Route: <span class="font-mono text-cyan-200">/setup-preview</span>
            </div>
          </div>

          <div class="mt-6 grid gap-6 xl:grid-cols-[minmax(0,1fr)_20rem]">
            <div>
              <p class="mb-3 text-xs font-semibold uppercase tracking-[0.18em] text-gray-400">
                Variant
              </p>
              <div class="flex flex-wrap gap-3">
                <%= for {key, label} <- @variants do %>
                  <.link
                    patch={preview_path(key, @mode)}
                    class={[
                      "rounded-full border px-4 py-2 text-sm font-medium transition-colors",
                      if(@variant == key,
                        do: "border-cyan-400 bg-cyan-400/15 text-cyan-100",
                        else:
                          "border-gray-700 bg-gray-950 text-gray-300 hover:border-gray-500 hover:text-white"
                      )
                    ]}
                  >
                    {label}
                  </.link>
                <% end %>
              </div>
            </div>

            <div>
              <p class="mb-3 text-xs font-semibold uppercase tracking-[0.18em] text-gray-400">
                Flow mode
              </p>
              <div class="flex gap-3">
                <.link
                  patch={preview_path(@variant, :first_run)}
                  class={[
                    "flex-1 rounded-2xl border px-4 py-3 text-left transition-colors",
                    if(@mode == :first_run,
                      do: "border-emerald-400 bg-emerald-400/10 text-emerald-100",
                      else:
                        "border-gray-700 bg-gray-950 text-gray-300 hover:border-gray-500 hover:text-white"
                    )
                  ]}
                >
                  <div class="text-sm font-semibold">First run</div>
                  <div class="mt-1 text-xs text-inherit/80">
                    Blocking wizard for missing Arr config
                  </div>
                </.link>

                <.link
                  patch={preview_path(@variant, :repair)}
                  class={[
                    "flex-1 rounded-2xl border px-4 py-3 text-left transition-colors",
                    if(@mode == :repair,
                      do: "border-amber-400 bg-amber-400/10 text-amber-100",
                      else:
                        "border-gray-700 bg-gray-950 text-gray-300 hover:border-gray-500 hover:text-white"
                    )
                  ]}
                >
                  <div class="text-sm font-semibold">Repair</div>
                  <div class="mt-1 text-xs text-inherit/80">
                    Toast entry for an unreachable saved config
                  </div>
                </.link>
              </div>
            </div>
          </div>
        </div>

        <div class="mb-6 grid gap-4 lg:grid-cols-3">
          <div class="rounded-2xl border border-gray-800 bg-gray-900/80 p-4">
            <div class="text-xs uppercase tracking-[0.18em] text-gray-500">Chosen pattern</div>
            <div class="mt-2 text-lg font-semibold text-white">Hybrid setup + repair</div>
            <p class="mt-2 text-sm text-gray-300">
              Missing Sonarr or Radarr redirects into setup. Broken saved configs stay non-blocking
              and offer a repair CTA.
            </p>
          </div>

          <div class="rounded-2xl border border-gray-800 bg-gray-900/80 p-4">
            <div class="text-xs uppercase tracking-[0.18em] text-gray-500">What changes</div>
            <div class="mt-2 text-lg font-semibold text-white">
              Copy density, hierarchy, and operator feel
            </div>
            <p class="mt-2 text-sm text-gray-300">
              Each variant keeps the same behavior but changes the visual treatment, pacing, and
              emphasis.
            </p>
          </div>

          <div class="rounded-2xl border border-gray-800 bg-gray-900/80 p-4">
            <div class="text-xs uppercase tracking-[0.18em] text-gray-500">Preview data</div>
            <div class="mt-2 text-lg font-semibold text-white">Stubbed, not wired</div>
            <p class="mt-2 text-sm text-gray-300">
              These previews use representative setup states so you can choose a look before the
              production flow is fully implemented.
            </p>
          </div>
        </div>

        {render_variant(assigns)}
      </div>
    </div>
    """
  end

  defp render_variant(%{variant: "guided"} = assigns) do
    ~H"""
    <.guided_onboarding preview={@preview} />
    """
  end

  defp render_variant(%{variant: "dashboard"} = assigns) do
    ~H"""
    <.dashboard_native preview={@preview} />
    """
  end

  defp render_variant(%{variant: "diagnostic"} = assigns) do
    ~H"""
    <.diagnostic_first preview={@preview} />
    """
  end

  defp render_variant(%{variant: "split"} = assigns) do
    ~H"""
    <.split_pane preview={@preview} />
    """
  end

  defp render_variant(assigns) do
    ~H"""
    <.minimal_calm preview={@preview} />
    """
  end

  defp preview_path(variant, mode) do
    mode_value = if mode == :repair, do: "repair", else: "first-run"
    ~p"/setup-preview?#{[variant: variant, mode: mode_value]}"
  end

  defp normalize_variant(value) when is_binary(value) do
    if Enum.any?(@variants, fn {key, _label} -> key == value end), do: value, else: "guided"
  end

  defp normalize_variant(_value), do: "guided"

  defp normalize_mode("repair"), do: :repair
  defp normalize_mode(_value), do: :first_run

  defp build_preview(:repair) do
    %{
      mode: :repair,
      headline: "Repair your Radarr connection without stopping the rest of the app",
      subheadline:
        "Reencodarr can keep running, but movie sync and webhook reconciliation need attention.",
      toast_title: "Radarr needs attention",
      toast_body:
        "The last Radarr status check failed. Re-test the connection or update the endpoint.",
      active_service: "Radarr",
      services: [
        %{
          name: "Sonarr",
          status: :healthy,
          url: "http://sonarr.lan:8989",
          step_label: "Healthy",
          detail: "Connection validated 2 minutes ago. Webhook target is in sync.",
          cta: "View settings"
        },
        %{
          name: "Radarr",
          status: :error,
          url: "http://radarr.lan:7878",
          step_label: "Needs repair",
          detail:
            "System status timed out. The host responded slowly after the last API key rotation.",
          cta: "Repair connection"
        }
      ]
    }
  end

  defp build_preview(:first_run) do
    %{
      mode: :first_run,
      headline: "Connect Sonarr and Radarr before Reencodarr starts managing your library",
      subheadline:
        "This guided preview shows how first-run setup could stage the Arr integrations before normal dashboard use.",
      toast_title: "Setup required",
      toast_body: "Both Sonarr and Radarr are required before setup is complete.",
      active_service: "Sonarr",
      services: [
        %{
          name: "Sonarr",
          status: :missing,
          url: "Add base URL and API key",
          step_label: "Step 1",
          detail:
            "Series sync, rename events, and delete events all flow through this connection.",
          cta: "Configure Sonarr"
        },
        %{
          name: "Radarr",
          status: :pending,
          url: "Queued after Sonarr",
          step_label: "Step 2",
          detail: "Movie sync and movie-file remediation unlock after Sonarr is connected.",
          cta: "Configure Radarr"
        }
      ]
    }
  end
end
