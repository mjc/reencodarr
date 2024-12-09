defmodule ReencodarrWeb.ConfigLive.FormComponent do
  use ReencodarrWeb, :live_component

  alias Reencodarr.Services

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage config records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="config-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:url]} type="text" label="Url" />
        <.input field={@form[:api_key]} type="text" label="Api key" />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <.input
          field={@form[:service_type]}
          type="select"
          label="Service type"
          prompt="Choose a value"
          options={Ecto.Enum.values(Reencodarr.Services.Config, :service_type)}
        />
        <:actions>
          <.button phx-disable-with="Saving...">Save Config</.button>
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
     |> assign_new(:form, fn ->
       to_form(Services.change_config(config))
     end)}
  end

  @impl true
  def handle_event("validate", %{"config" => config_params}, socket) do
    changeset = Services.change_config(socket.assigns.config, config_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"config" => config_params}, socket) do
    save_config(socket, socket.assigns.action, config_params)
  end

  defp save_config(socket, :edit, config_params) do
    case Services.update_config(socket.assigns.config, config_params) do
      {:ok, config} ->
        notify_parent({:saved, config})

        {:noreply,
         socket
         |> put_flash(:info, "Config updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_config(socket, :new, config_params) do
    case Services.create_config(config_params) do
      {:ok, config} ->
        notify_parent({:saved, config})

        {:noreply,
         socket
         |> put_flash(:info, "Config created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
