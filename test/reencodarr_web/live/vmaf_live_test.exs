defmodule ReencodarrWeb.VmafLiveTest do
  use ReencodarrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Reencodarr.MediaFixtures

  @create_attrs %{crf: 120.5, score: 120.5}
  @update_attrs %{crf: 456.7, score: 456.7}
  @invalid_attrs %{crf: nil, score: nil}

  defp create_vmaf(_) do
    vmaf = vmaf_fixture()
    %{vmaf: vmaf}
  end

  describe "Index" do
    setup [:create_vmaf]

    test "lists all vmafs", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/vmafs")

      assert html =~ "Listing Vmafs"
    end

    test "saves new vmaf", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/vmafs")

      assert index_live |> element("a", "New Vmaf") |> render_click() =~
               "New Vmaf"

      assert_patch(index_live, ~p"/vmafs/new")

      assert index_live
             |> form("#vmaf-form", vmaf: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#vmaf-form", vmaf: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/vmafs")

      html = render(index_live)
      assert html =~ "Vmaf created successfully"
    end

    test "updates vmaf in listing", %{conn: conn, vmaf: vmaf} do
      {:ok, index_live, _html} = live(conn, ~p"/vmafs")

      assert index_live |> element("#vmafs-#{vmaf.id} a", "Edit") |> render_click() =~
               "Edit Vmaf"

      assert_patch(index_live, ~p"/vmafs/#{vmaf}/edit")

      assert index_live
             |> form("#vmaf-form", vmaf: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#vmaf-form", vmaf: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/vmafs")

      html = render(index_live)
      assert html =~ "Vmaf updated successfully"
    end

    test "deletes vmaf in listing", %{conn: conn, vmaf: vmaf} do
      {:ok, index_live, _html} = live(conn, ~p"/vmafs")

      assert index_live |> element("#vmafs-#{vmaf.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#vmafs-#{vmaf.id}")
    end
  end

  describe "Show" do
    setup [:create_vmaf]

    test "displays vmaf", %{conn: conn, vmaf: vmaf} do
      {:ok, _show_live, html} = live(conn, ~p"/vmafs/#{vmaf}")

      assert html =~ "Show Vmaf"
    end

    test "updates vmaf within modal", %{conn: conn, vmaf: vmaf} do
      {:ok, show_live, _html} = live(conn, ~p"/vmafs/#{vmaf}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Vmaf"

      assert_patch(show_live, ~p"/vmafs/#{vmaf}/show/edit")

      assert show_live
             |> form("#vmaf-form", vmaf: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#vmaf-form", vmaf: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/vmafs/#{vmaf}")

      html = render(show_live)
      assert html =~ "Vmaf updated successfully"
    end
  end
end
