defmodule ReencodarrWeb.VideoLiveTest do
  use ReencodarrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Reencodarr.MediaFixtures

  @create_attrs %{size: 42, path: "some path", bitrate: 42}
  @update_attrs %{size: 43, path: "some updated path", bitrate: 43}
  @invalid_attrs %{size: nil, path: nil, bitrate: nil}

  defp create_video(_) do
    video = video_fixture()
    %{video: video}
  end

  describe "Index" do
    setup [:create_video]

    test "lists all videos", %{conn: conn, video: video} do
      {:ok, _index_live, html} = live(conn, ~p"/videos")

      assert html =~ "Listing Videos"
      assert html =~ video.path
    end

    test "saves new video", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/videos")

      assert index_live |> element("a", "New Video") |> render_click() =~
               "New Video"

      assert_patch(index_live, ~p"/videos/new")

      assert index_live
             |> form("#video-form", video: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#video-form", video: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/videos")

      html = render(index_live)
      assert html =~ "Video created successfully"
      assert html =~ "some path"
    end

    test "updates video in listing", %{conn: conn, video: video} do
      {:ok, index_live, _html} = live(conn, ~p"/videos")

      assert index_live |> element("#videos-#{video.id} a", "Edit") |> render_click() =~
               "Edit Video"

      assert_patch(index_live, ~p"/videos/#{video}/edit")

      assert index_live
             |> form("#video-form", video: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#video-form", video: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/videos")

      html = render(index_live)
      assert html =~ "Video updated successfully"
      assert html =~ "some updated path"
    end

    test "deletes video in listing", %{conn: conn, video: video} do
      {:ok, index_live, _html} = live(conn, ~p"/videos")

      assert index_live |> element("#videos-#{video.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#videos-#{video.id}")
    end
  end

  describe "Show" do
    setup [:create_video]

    test "displays video", %{conn: conn, video: video} do
      {:ok, _show_live, html} = live(conn, ~p"/videos/#{video}")

      assert html =~ "Show Video"
      assert html =~ video.path
    end

    test "updates video within modal", %{conn: conn, video: video} do
      {:ok, show_live, _html} = live(conn, ~p"/videos/#{video}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Video"

      assert_patch(show_live, ~p"/videos/#{video}/show/edit")

      assert show_live
             |> form("#video-form", video: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#video-form", video: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/videos/#{video}")

      html = render(show_live)
      assert html =~ "Video updated successfully"
      assert html =~ "some updated path"
    end
  end
end
