defmodule ReencodarrWeb.ConfigLiveTest do
  use ReencodarrWeb.ConnCase
  use ExUnit.Case

  import Phoenix.LiveViewTest
  import Reencodarr.ServicesFixtures
  import ExUnit.CaptureLog

  @create_attrs %{
    api_key: "some api_key",
    enabled: true,
    service_type: :radarr,
    url: "some url"
  }

  @update_attrs %{
    api_key: "some updated api_key",
    enabled: false,
    service_type: :plex,
    url: "some updated url"
  }

  @invalid_attrs %{
    api_key: nil,
    enabled: false,
    service_type: nil,
    url: nil
  }

  defp create_config(_) do
    config = config_fixture()
    %{config: config}
  end

  describe "Index" do
    setup do
      config = config_fixture()
      %{config: config}
    end

    test "lists all configs", %{conn: conn, config: config} do
      capture_log(fn ->
        {:ok, _index_live, html} = live(conn, ~p"/configs")

        assert html =~ "Listing Configs"
        assert html =~ config.api_key
      end)
    end

    test "saves new config", %{conn: conn} do
      capture_log(fn ->
        {:ok, index_live, _html} = live(conn, ~p"/configs")

        assert index_live |> element("a", "New Config") |> render_click() =~ "New Config"
        assert_patch(index_live, ~p"/configs/new")

        assert index_live
               |> form("#config-form", config: @invalid_attrs)
               |> render_change() =~ "can&#39;t be blank"

        assert index_live
               |> form("#config-form", config: @create_attrs)
               |> render_submit()

        assert_patch(index_live, ~p"/configs")

        html = render(index_live)
        assert html =~ "Config created successfully"
        assert html =~ "some api_key"
      end)
    end

    test "updates config in listing", %{conn: conn, config: config} do
      capture_log(fn ->
        {:ok, index_live, _html} = live(conn, ~p"/configs")

        assert index_live |> element("#configs-#{config.id} a", "Edit") |> render_click() =~
                 "Edit Config"

        assert_patch(index_live, ~p"/configs/#{config}/edit")

        assert index_live
               |> form("#config-form", config: @invalid_attrs)
               |> render_change() =~ "can&#39;t be blank"

        assert index_live
               |> form("#config-form", config: @update_attrs)
               |> render_submit()

        assert_patch(index_live, ~p"/configs")

        html = render(index_live)
        assert html =~ "Config updated successfully"
        assert html =~ "some updated api_key"
      end)
    end

    test "deletes config in listing", %{conn: conn, config: config} do
      capture_log(fn ->
        {:ok, index_live, _html} = live(conn, ~p"/configs")

        assert index_live |> element("#configs-#{config.id} a", "Delete") |> render_click()
        refute has_element?(index_live, "#configs-#{config.id}")
      end)
    end
  end

  describe "Show" do
    setup [:create_config]

    test "displays config", %{conn: conn, config: config} do
      capture_log(fn ->
        {:ok, _show_live, html} = live(conn, ~p"/configs/#{config}")

        assert html =~ "Show Config"
        assert html =~ config.api_key
      end)
    end

    test "updates config within modal", %{conn: conn, config: config} do
      capture_log(fn ->
        {:ok, show_live, _html} = live(conn, ~p"/configs/#{config}")

        assert show_live |> element("a", "Edit") |> render_click() =~
                 "Edit Config"

        assert_patch(show_live, ~p"/configs/#{config}/show/edit")

        assert show_live
               |> form("#config-form", config: @invalid_attrs)
               |> render_change() =~ "can&#39;t be blank"

        assert show_live
               |> form("#config-form", config: @update_attrs)
               |> render_submit()

        assert_patch(show_live, ~p"/configs/#{config}")

        html = render(show_live)
        assert html =~ "Config updated successfully"
        assert html =~ "some updated api_key"
      end)
    end
  end
end
