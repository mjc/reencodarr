defmodule ReencodarrWeb.ConfigLive.FormComponent do
  use ReencodarrWeb, :live_component

  alias Reencodarr.Services

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Service endpoints and sync settings.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="config-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:url]} type="text" label="URL" />
        <.input field={@form[:api_key]} type="password" label="API key" autocomplete="off" />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <.input
          field={@form[:service_type]}
          type="select"
          label="Service"
          prompt="Select a service"
          options={Ecto.Enum.values(Reencodarr.Services.Config, :service_type)}
        />
        <:actions>
          <.button phx-disable-with="Saving...">Save source</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{config: config} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(Services.change_config(config)))}
  end

  @impl true
  def handle_event("validate", %{"config" => config_params}, socket) do
    changeset = Services.change_config(socket.assigns.config, config_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"config" => config_params}, socket) do
    save_config(socket, socket.assigns.action, config_params)
  end

  defp save_config(socket, action, params) do
    result =
      case action do
        :edit -> Services.update_config(socket.assigns.config, params)
        :new -> Services.create_config(params)
      end

    case result do
      {:ok, config} ->
        notify_parent({:saved, config})
        verb = if action == :new, do: "created", else: "updated"

        {:noreply,
         socket
         |> put_flash(:info, "Source #{verb}")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
