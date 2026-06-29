defmodule ReencodarrWeb.Live.FlopList do
  @moduledoc """
  Shared LiveView helpers for Flop-backed list pagination.

  The list LiveViews keep their filters in URL params and pass Flop metadata to
  this module for consistent labels, page links, and page parsing.
  """

  use Phoenix.Component

  import Flop.Phoenix

  alias Reencodarr.Core.Parsers

  attr :id, :string, default: "flop-pagination"
  attr :meta, Flop.Meta, required: true
  attr :path, :any, default: nil
  attr :base_path, :string, default: nil
  attr :query, :map, default: %{}
  attr :mode, :atom, default: :simple, values: [:simple, :full]
  attr :page_links, :integer, default: 5
  attr :target, :string, default: nil
  attr :class, :string, default: nil

  @doc """
  Renders pagination controls for a `%Flop.Meta{}` result.

  Pass either a Flop `:path` callback or a `:base_path` plus current `:query`.
  The `:simple` mode renders previous/next links only; `:full` also renders page
  number links.
  """
  def flop_pagination(assigns) do
    path = pagination_path(assigns)
    page_links = if assigns.mode == :simple, do: :none, else: assigns.page_links

    assigns =
      assign(assigns,
        path: path,
        page_links: page_links,
        label: pagination_label(assigns.meta),
        nav_id: "#{assigns.id}-nav"
      )

    ~H"""
    <div
      id={@id}
      class={["flex items-center justify-between text-sm text-gray-400", @class]}
      data-role="flop-pagination"
    >
      <span data-role="flop-pagination-label">{@label}</span>
      <.pagination
        meta={@meta}
        path={@path}
        target={@target}
        page_links={@page_links}
        page_link_attrs={page_link_attrs()}
        current_page_link_attrs={current_page_link_attrs()}
        disabled_link_attrs={disabled_link_attrs()}
        id={@nav_id}
        data-role="flop-pagination-nav"
      >
        <:previous attrs={nav_button_attrs("flop-pagination-prev")}>Previous</:previous>
        <:next attrs={nav_button_attrs("flop-pagination-next")}>Next</:next>
      </.pagination>
    </div>
    """
  end

  @doc """
  Builds the compact result range label shown beside pagination controls.
  """
  @spec pagination_label(Flop.Meta.t()) :: String.t()
  def pagination_label(%Flop.Meta{} = meta) do
    per_page = meta.page_size || 1
    total = meta.total_count || 0
    page = meta.current_page || 1

    page =
      if total > 0 do
        page |> max(1) |> min(total_pages(total, per_page))
      else
        max(page, 1)
      end

    pagination_range_label(page, per_page, total)
  end

  @doc """
  Returns the number of pages needed for a result count and page size.

  Empty result sets still return `1` so URL parsing and LiveView assigns have a
  stable page value.
  """
  @spec total_pages(non_neg_integer(), pos_integer()) :: pos_integer()
  def total_pages(total, _per_page) when total <= 0, do: 1
  def total_pages(total, per_page), do: max(ceil(total / per_page), 1)

  @doc """
  Parses a positive page number from request params.

  When `:total` and `:per_page` are provided, the page is clamped to the
  available range.
  """
  @spec parse_page(map(), pos_integer(), keyword()) :: pos_integer()
  def parse_page(params, default, opts \\ []) do
    page = params |> Map.get("page", "#{default}") |> Parsers.parse_int(default) |> max(1)

    with total when is_integer(total) <- Keyword.get(opts, :total),
         per_page when is_integer(per_page) <- Keyword.get(opts, :per_page) do
      page |> max(1) |> min(total_pages(total, per_page))
    else
      _ -> page
    end
  end

  @doc """
  Parses a page size from request params and falls back unless it is allowed.
  """
  @spec parse_per_page(map(), pos_integer(), [pos_integer()]) :: pos_integer()
  def parse_per_page(params, default, allowed) do
    params
    |> Map.get("per_page", "#{default}")
    |> Parsers.parse_int(default)
    |> then(&if(&1 in allowed, do: &1, else: default))
  end

  @doc """
  Returns normalized pagination assigns from request params.
  """
  @spec pagination_assigns(map(), pos_integer(), [pos_integer()], pos_integer()) :: %{
          page: pos_integer(),
          per_page: pos_integer()
        }
  def pagination_assigns(params, default_per_page, allowed_per_pages, default_page \\ 1) do
    %{
      page: parse_page(params, default_page),
      per_page: parse_per_page(params, default_per_page, allowed_per_pages)
    }
  end

  defp pagination_range_label(page, per_page, total) when total > 0 do
    first = (page - 1) * per_page + 1
    last = min(page * per_page, total)
    "#{first}-#{last} of #{total}"
  end

  defp pagination_range_label(_, _, _), do: "0 results"

  @doc """
  Flop path callback that preserves the current list query while changing page.
  """
  @spec flop_page_path(String.t(), map(), keyword()) :: String.t()
  def flop_page_path(base_path, query, flop_params) do
    page = Keyword.get(flop_params, :page, 1)
    patch_with_page(base_path, query, page)
  end

  @doc """
  Returns a LiveView patch path with `page` merged into existing query params.

  Page `1` is omitted from the URL so the canonical first page stays clean.
  """
  @spec patch_with_page(String.t(), map(), pos_integer()) :: String.t()
  def patch_with_page(base_path, query, page) when is_binary(base_path) and is_map(query) do
    query
    |> stringify_query()
    |> maybe_put_page(page)
    |> drop_empty()
    |> case do
      %{} = params when map_size(params) == 0 -> base_path
      params -> base_path <> "?" <> URI.encode_query(params)
    end
  end

  defp pagination_path(%{base_path: base_path, path: nil, query: query})
       when is_binary(base_path) do
    {__MODULE__, :flop_page_path, [base_path, query]}
  end

  defp pagination_path(%{path: path}) when not is_nil(path), do: path

  defp pagination_path(_assigns) do
    raise ArgumentError, "flop_pagination requires :path or :base_path"
  end

  defp stringify_query(query) do
    Map.new(query, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_put_page(query, 1), do: Map.delete(query, "page")
  defp maybe_put_page(query, page), do: Map.put(query, "page", to_string(page))

  defp drop_empty(query) do
    Map.reject(query, fn {_key, value} -> value in [nil, ""] end)
  end

  defp nav_button_attrs(role) do
    [
      class: nav_button_classes(),
      "data-role": role
    ]
  end

  defp nav_button_classes,
    do:
      "px-3 py-1 bg-gray-700 rounded text-gray-300 hover:bg-gray-600 disabled:opacity-40 disabled:cursor-not-allowed"

  defp page_link_attrs,
    do: [
      class: page_link_classes(),
      "data-role": "flop-pagination-page"
    ]

  defp current_page_link_attrs,
    do: [
      class: current_page_link_classes(),
      "data-role": "flop-pagination-page"
    ]

  defp disabled_link_attrs, do: [class: "opacity-40 cursor-not-allowed"]

  defp page_link_classes,
    do:
      "px-3 py-1.5 text-sm font-medium rounded text-gray-300 bg-gray-700 border border-gray-600 hover:bg-gray-600 transition-colors"

  defp current_page_link_classes,
    do: "px-3 py-1.5 text-sm font-medium rounded text-white bg-blue-600 border border-blue-600"
end
