defmodule ReencodarrWeb.LibraryLiveTest do
  use ReencodarrWeb.ConnCase

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  alias Reencodarr.Fixtures

  @create_attrs %{monitor: true, path: "some path"}
  @update_attrs %{monitor: false, path: "some updated path"}
  @invalid_attrs %{monitor: false, path: nil}

  defp create_library(_) do
    library = Fixtures.library_fixture()
    %{library: library}
  end

  defp with_captured_logs(fun) do
    capture_log(fun)
  end

  describe "Index" do
    setup [:create_library]

    test "lists all libraries", %{conn: conn, library: library} do
      with_captured_logs(fn ->
        {:ok, _index_live, html} = live(conn, ~p"/libraries")

        assert html =~ "Listing Libraries"
        assert html =~ library.path
      end)
    end

    test "saves new library", %{conn: conn} do
      with_captured_logs(fn ->
        {:ok, index_live, _html} = live(conn, ~p"/libraries")

        assert index_live |> element("a", "New Library") |> render_click() =~
                 "New Library"

        assert_patch(index_live, ~p"/libraries/new")

        assert index_live
               |> form("#library-form", library: @invalid_attrs)
               |> render_change() =~ "can&#39;t be blank"

        assert index_live
               |> form("#library-form", library: @create_attrs)
               |> render_submit()

        assert_patch(index_live, ~p"/libraries")

        html = render(index_live)
        assert html =~ "Library created successfully"
        assert html =~ "some path"
      end)
    end

    test "updates library in listing", %{conn: conn, library: library} do
      with_captured_logs(fn ->
        {:ok, index_live, _html} = live(conn, ~p"/libraries")

        assert index_live |> element("#libraries-#{library.id} a", "Edit") |> render_click() =~
                 "Edit Library"

        assert_patch(index_live, ~p"/libraries/#{library}/edit")

        assert index_live
               |> form("#library-form", library: @invalid_attrs)
               |> render_change() =~ "can&#39;t be blank"

        assert index_live
               |> form("#library-form", library: @update_attrs)
               |> render_submit()

        assert_patch(index_live, ~p"/libraries")

        html = render(index_live)
        assert html =~ "Library updated successfully"
        assert html =~ "some updated path"
      end)
    end

    test "deletes library in listing", %{conn: conn, library: library} do
      with_captured_logs(fn ->
        {:ok, index_live, _html} = live(conn, ~p"/libraries")

        assert index_live |> element("#libraries-#{library.id} a", "Delete") |> render_click()
        refute has_element?(index_live, "#libraries-#{library.id}")
      end)
    end
  end

  describe "Show" do
    setup [:create_library]

    test "displays library", %{conn: conn, library: library} do
      with_captured_logs(fn ->
        {:ok, _show_live, html} = live(conn, ~p"/libraries/#{library}")

        assert html =~ "Show Library"
        assert html =~ library.path
      end)
    end

    test "updates library within modal", %{conn: conn, library: library} do
      with_captured_logs(fn ->
        {:ok, show_live, _html} = live(conn, ~p"/libraries/#{library}")

        assert show_live |> element("a", "Edit") |> render_click() =~
                 "Edit Library"

        assert_patch(show_live, ~p"/libraries/#{library}/show/edit")

        assert show_live
               |> form("#library-form", library: @invalid_attrs)
               |> render_change() =~ "can&#39;t be blank"

        assert show_live
               |> form("#library-form", library: @update_attrs)
               |> render_submit()

        assert_patch(show_live, ~p"/libraries/#{library}")

        html = render(show_live)
        assert html =~ "Library updated successfully"
        assert html =~ "some updated path"
      end)
    end
  end
end
