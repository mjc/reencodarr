defmodule ReencodarrWeb.LibraryLive.FormComponent do
  use ReencodarrWeb, :live_component

  alias Reencodarr.Media

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Root path used to match synced media.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="library-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:path]} type="text" label="Path" />
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
     |> assign(:form, to_form(Media.change_library(library)))}
  end

  @impl true
  def handle_event("validate", %{"library" => library_params}, socket) do
    changeset = Media.change_library(socket.assigns.library, library_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"library" => library_params}, socket) do
    save_library(socket, socket.assigns.action, library_params)
  end

  defp save_library(socket, action, params) do
    result =
      case action do
        :edit -> Media.update_library(socket.assigns.library, params)
        :new -> Media.create_library(params)
      end

    case result do
      {:ok, library} ->
        notify_parent({:saved, library})
        verb = if action == :new, do: "created", else: "updated"

        {:noreply,
         socket
         |> put_flash(:info, "Library #{verb} successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
