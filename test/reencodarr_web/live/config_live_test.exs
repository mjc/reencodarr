defmodule ReencodarrWeb.ConfigLiveTest do
  use ReencodarrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Reencodarr.ServicesFixtures

  @create_attrs %{api_key: "some api_key", enabled: true, service_type: :radarr, url: "some url"}
  @update_attrs %{
    api_key: "some updated api_key",
    enabled: false,
    service_type: :plex,
    url: "some updated url"
  }
  @invalid_attrs %{api_key: nil, enabled: false, service_type: nil, url: nil}

  defp create_config(_) do
    config = config_fixture()
    %{config: config}
  end

  # Test helper functions to reduce repetition
  defp test_form_validation(
         live_view,
         form_id,
         invalid_attrs,
         expected_error \\ "can&#39;t be blank"
       ) do
    live_view
    |> form(form_id, config: invalid_attrs)
    |> render_change() =~ expected_error
  end

  defp test_form_submission(live_view, form_id, attrs) do
    live_view
    |> form(form_id, config: attrs)
    |> render_submit()
  end

  defp click_element_and_assert(live_view, selector, text, expected_content) do
    assert live_view |> element(selector, text) |> render_click() =~ expected_content
  end

  describe "Index" do
    setup [:create_config]

    test "lists all configs", %{conn: conn, config: config} do
      {:ok, _index_live, html} = live(conn, ~p"/configs")

      assert html =~ "Listing Configs"
      assert html =~ config.api_key
    end

    test "saves new config", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/configs")

      click_element_and_assert(index_live, "a", "New Config", "New Config")
      assert_patch(index_live, ~p"/configs/new")

      assert test_form_validation(index_live, "#config-form", @invalid_attrs)
      test_form_submission(index_live, "#config-form", @create_attrs)

      assert_patch(index_live, ~p"/configs")

      html = render(index_live)
      assert html =~ "Config created successfully"
      assert html =~ "some api_key"
    end

    test "updates config in listing", %{conn: conn, config: config} do
      {:ok, index_live, _html} = live(conn, ~p"/configs")

      click_element_and_assert(index_live, "#configs-#{config.id} a", "Edit", "Edit Config")
      assert_patch(index_live, ~p"/configs/#{config}/edit")

      assert test_form_validation(index_live, "#config-form", @invalid_attrs)
      test_form_submission(index_live, "#config-form", @update_attrs)

      assert_patch(index_live, ~p"/configs")

      html = render(index_live)
      assert html =~ "Config updated successfully"
      assert html =~ "some updated api_key"
    end

    test "deletes config in listing", %{conn: conn, config: config} do
      {:ok, index_live, _html} = live(conn, ~p"/configs")

      assert index_live |> element("#configs-#{config.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#configs-#{config.id}")
    end
  end

  describe "Show" do
    setup [:create_config]

    test "displays config", %{conn: conn, config: config} do
      {:ok, _show_live, html} = live(conn, ~p"/configs/#{config}")

      assert html =~ "Show Config"
      assert html =~ config.api_key
    end

    test "updates config within modal", %{conn: conn, config: config} do
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
    end
  end
end
