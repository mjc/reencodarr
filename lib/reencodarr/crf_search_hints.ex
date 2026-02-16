defmodule Reencodarr.CrfSearchHints do
  @moduledoc """
  Provides season-aware CRF range narrowing for TV show episodes.

  Within the same season, episodes with the same resolution and HDR status
  tend to have similar optimal CRF values (avg σ ≈ 2.8 CRF points across
  3000+ episodes). This module exploits that pattern by querying sibling
  episodes that already have chosen CRF values and narrowing the search
  range for subsequent episodes.

  ## Strategy

  - First attempt: use narrowed range from sibling CRFs (±6 margin for ~95% coverage)
  - Retry (after failure): fall back to standard range {8, 40}
  - No siblings found: use standard range
  - Movies (no season folder): use standard range
  """

  import Ecto.Query

  alias Reencodarr.Media.Video
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  require Logger

  @default_min_crf 8
  @default_max_crf 40
  @default_range {@default_min_crf, @default_max_crf}

  # Margin around sibling CRF range: ±6 covers ~95% of observed variance (2σ where σ ≈ 2.8)
  @margin 6

  # Absolute bounds - never go outside these regardless of sibling data
  @absolute_min_crf 8
  @absolute_max_crf 55

  @doc """
  Returns a CRF search range for the given video.

  On retry, always returns the default range `{8, 40}`.
  Otherwise, attempts to narrow the range based on sibling episodes
  in the same season with matching resolution and HDR status.

  ## Options

  - `retry: true` - forces default range (used after a narrowed search fails)

  ## Returns

  `{min_crf, max_crf}` tuple
  """
  @spec crf_range(Video.t(), keyword()) :: {integer(), integer()}
  def crf_range(_video, opts \\ [])

  def crf_range(_video, retry: true), do: @default_range

  def crf_range(video, _opts) do
    case sibling_crfs(video) do
      [] ->
        @default_range

      crfs ->
        narrow_range(crfs)
    end
  end

  @doc """
  Finds chosen CRF values from sibling episodes.

  Siblings are videos in the same directory (season folder) with matching
  resolution and HDR status that already have a chosen VMAF record.
  The target video itself is excluded.

  Returns an empty list for movies or videos without a recognizable
  season folder structure.
  """
  @spec sibling_crfs(Video.t() | map()) :: [float()]
  def sibling_crfs(%{id: video_id, path: path, height: height, width: width, hdr: hdr}) do
    season_dir = Path.dirname(path)

    # Only proceed if the path looks like it has a season folder
    if season_folder?(season_dir) do
      query_sibling_crfs(video_id, season_dir, height, width, hdr)
    else
      []
    end
  end

  # Fallback for maps missing required fields — return default range
  def sibling_crfs(_video), do: []

  @doc """
  Returns true if the given CRF range is narrower than the default.
  """
  @spec narrowed_range?({number(), number()}) :: boolean()
  def narrowed_range?({min_crf, max_crf}) do
    min_crf > @default_min_crf or max_crf < @default_max_crf
  end

  # Private functions

  defp season_folder?(dir) do
    basename = Path.basename(dir)
    Regex.match?(~r/^[Ss](?:eason\s*)?0*\d+$/i, basename)
  end

  defp query_sibling_crfs(exclude_video_id, season_dir, height, width, hdr) do
    # Use LIKE to match videos in the same directory
    dir_prefix = season_dir <> "/"

    base_query =
      from v in Video,
        join: vmaf in Vmaf,
        on: vmaf.video_id == v.id,
        where: v.id != ^exclude_video_id,
        where: like(v.path, ^"#{dir_prefix}%"),
        where: v.height == ^height,
        where: v.width == ^width,
        where: vmaf.chosen == true,
        select: vmaf.crf

    # Match HDR status: both nil (SDR) or both non-nil (HDR)
    query =
      if is_nil(hdr) do
        from [v, _vmaf] in base_query, where: is_nil(v.hdr)
      else
        from [v, _vmaf] in base_query, where: not is_nil(v.hdr)
      end

    Repo.all(query)
  end

  defp narrow_range(crfs) do
    min_sibling = Enum.min(crfs)
    max_sibling = Enum.max(crfs)

    min_crf = max(@absolute_min_crf, floor(min_sibling - @margin))
    max_crf = min(@absolute_max_crf, ceil(max_sibling + @margin))

    {min_crf, max_crf}
  end
end
