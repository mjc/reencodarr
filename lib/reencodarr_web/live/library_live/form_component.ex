defmodule ReencodarrWeb.LibraryLive.FormComponent do
  use ReencodarrWeb, :live_component

  alias Reencodarr.Media

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage library records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="library-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:path]} type="text" label="Path" />
        <.input field={@form[:monitor]} type="checkbox" label="Monitor" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Library</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{library: library} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Media.change_library(library))
     end)}
  end

  @impl true
  def handle_event("validate", %{"library" => library_params}, socket) do
    changeset = Media.change_library(socket.assigns.library, library_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"library" => library_params}, socket) do
    save_library(socket, socket.assigns.action, library_params)
  end

  defp save_library(socket, :edit, library_params) do
    case Media.update_library(socket.assigns.library, library_params) do
      {:ok, library} ->
        notify_parent({:saved, library})

        {:noreply,
         socket
         |> put_flash(:info, "Library updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_library(socket, :new, library_params) do
    case Media.create_library(library_params) do
      {:ok, library} ->
        notify_parent({:saved, library})

        {:noreply,
         socket
         |> put_flash(:info, "Library created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
