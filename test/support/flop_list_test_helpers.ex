defmodule ReencodarrWeb.FlopListTestHelpers do
  @moduledoc false

  import Phoenix.LiveViewTest

  @spec pagination_label_from_html(String.t()) :: String.t() | nil
  def pagination_label_from_html(html) do
    case Regex.run(~r/data-role="flop-pagination-label"[^>]*>([^<]+)/, html) do
      [_, label] -> String.trim(label)
      _ -> nil
    end
  end

  @spec current_page_from_html(String.t()) :: pos_integer() | nil
  def current_page_from_html(html) do
    case Regex.run(~r/aria-current="page"[^>]*>\s*(\d+)/s, html) do
      [_, page] -> String.to_integer(page)
      _ -> if String.contains?(html, ~s(data-role="flop-pagination")), do: 1, else: nil
    end
  end

  @spec current_page_from_meta(Flop.Meta.t()) :: pos_integer()
  def current_page_from_meta(%Flop.Meta{current_page: page}) when is_integer(page), do: page
  def current_page_from_meta(_meta), do: 1

  @spec total_pages_from_html(String.t()) :: pos_integer()
  def total_pages_from_html(html) do
    case Regex.scan(~r/data-role="flop-pagination-page"/, html) do
      [] -> 1
      pages -> length(pages)
    end
  end

  @spec assert_filter_in_url(String.t(), String.t(), String.t()) :: :ok
  def assert_filter_in_url(path, key, value) do
    query = path |> URI.parse() |> Map.get(:query, "") |> URI.decode_query()

    if Map.get(query, key) != value do
      raise ExUnit.AssertionError,
            "expected #{inspect(key)}=#{inspect(value)} in #{path}, got #{inspect(query)}"
    end

    :ok
  end

  @spec assert_flop_patch(Phoenix.LiveViewTest.view(), String.t()) :: :ok
  def assert_flop_patch(view, expected_path) do
    assert_patch(view, expected_path)
  end

  @spec click_flop_next(Phoenix.LiveViewTest.view()) :: String.t()
  def click_flop_next(view) do
    view
    |> element("a[data-role='flop-pagination-next']")
    |> render_click()
  end
end
