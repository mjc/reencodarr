defmodule ReencodarrWeb.VmafLive.FormComponent do
  use ReencodarrWeb, :live_component

  alias Reencodarr.Media

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage vmaf records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="vmaf-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:score]} type="number" label="Score" step="any" />
        <.input field={@form[:crf]} type="number" label="Crf" step="any" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Vmaf</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{vmaf: vmaf} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Media.change_vmaf(vmaf))
     end)}
  end

  @impl true
  def handle_event("validate", %{"vmaf" => vmaf_params}, socket) do
    changeset = Media.change_vmaf(socket.assigns.vmaf, vmaf_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"vmaf" => vmaf_params}, socket) do
    save_vmaf(socket, socket.assigns.action, vmaf_params)
  end

  defp save_vmaf(socket, :edit, vmaf_params) do
    case Media.update_vmaf(socket.assigns.vmaf, vmaf_params) do
      {:ok, vmaf} ->
        notify_parent({:saved, vmaf})

        {:noreply,
         socket
         |> put_flash(:info, "Vmaf updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_vmaf(socket, :new, vmaf_params) do
    case Media.create_vmaf(vmaf_params) do
      {:ok, vmaf} ->
        notify_parent({:saved, vmaf})

        {:noreply,
         socket
         |> put_flash(:info, "Vmaf created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
