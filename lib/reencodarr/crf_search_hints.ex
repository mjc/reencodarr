defmodule Reencodarr.CrfSearchHints do
  @moduledoc """
  Provides CRF range narrowing using existing VMAF records and season-aware sibling data.

  ## Priority chain

  1. **Own VMAF records** — `{crf, score}` pairs from any prior records for the exact video
     (including unchosen ones from failed searches). Bracketed against the target, margin ±2.
  2. **Sibling VMAF records** — chosen `{crf, score}` pairs from episodes in the same season
     folder with matching resolution and HDR status. Bracketed against the target, margin ±4.
  3. **Default range** — `{5, 70}` (full SVT-AV1 range).

  ## Bracketing logic

  Given `{crf, score}` pairs and a target VMAF:

  - **Passing** (score ≥ target): highest-CRF passing record is our floor — the least aggressive
    CRF that still met quality. `min_crf = highest_passing_crf − margin`.
  - **Failing** (score < target): lowest-CRF failing record is our ceiling — even that aggressive
    a CRF was not enough. `max_crf = lowest_failing_crf + margin`.
  - Only passing: ceiling is `highest_passing_crf + margin * 2` (search a bit above too).
  - Only failing: floor is `@absolute_min_crf` (go as low as needed).

  ## Retry behaviour

  On retry, the full default range `{5, 70}` is always used to guarantee a wider
  search. Using own records on retry re-narrows to the same failing range and
  causes an infinite retry loop.
  """

  import Ecto.Query

  alias Reencodarr.Media.Video
  alias Reencodarr.Media.Vmaf
  alias Reencodarr.Repo

  require Logger

  @default_min_crf 5
  @default_max_crf 70
  @default_range {@default_min_crf, @default_max_crf}

  # Margin for own records: tight — same source video
  @own_margin 2

  # Margin for sibling records: slightly wider — same season, different content
  @sibling_margin 4

  # Absolute bounds — never exceed these
  @absolute_min_crf 5
  @absolute_max_crf 70

  @doc """
  Returns a CRF search range for the given video and VMAF target.

  Checks in priority order:
  1. Own VMAF records — bracketed against `target_vmaf`, margin ±#{@own_margin}
  2. Sibling chosen records — bracketed against `target_vmaf`, margin ±#{@sibling_margin}
  3. Default range `{#{@default_min_crf}, #{@default_max_crf}}`

  On retry, the full default range `{5, 70}` is always returned so that the
  search is guaranteed to be wider than any previously-attempted narrowed range.

  ## Options

  - `retry: true` — always return the default range `{#{@default_min_crf}, #{@default_max_crf}}`

  ## Returns

  `{min_crf, max_crf}` tuple
  """
  @spec crf_range(Video.t(), pos_integer(), keyword()) :: {integer(), integer()}
  def crf_range(video, target_vmaf, opts \\ [])

  def crf_range(_video, _target_vmaf, retry: true) do
    @default_range
  end

  def crf_range(video, target_vmaf, _opts) do
    case {own_vmaf_records(video), sibling_vmaf_records(video)} do
      {[_ | _] = own, _} -> bracket_range(own, target_vmaf, @own_margin)
      {[], [_ | _] = siblings} -> bracket_range(siblings, target_vmaf, @sibling_margin)
      {[], []} -> @default_range
    end
  end

  @doc """
  Returns `{crf, score}` pairs from all VMAF records for the given video.

  Includes non-chosen records, so data from prior failed searches is utilised.
  Returns an empty list if the video has no VMAF records yet.
  """
  @spec own_vmaf_records(Video.t() | map()) :: [{float(), float()}]
  def own_vmaf_records(%{id: video_id}) do
    from(vmaf in Vmaf,
      where: vmaf.video_id == ^video_id,
      select: {vmaf.crf, vmaf.score}
    )
    |> Repo.all()
  end

  def own_vmaf_records(_), do: []

  @doc """
  Returns `{crf, score}` pairs from chosen VMAF records of sibling episodes.

  Siblings are videos in the same directory (season folder) with matching
  resolution and HDR status that already have a chosen VMAF record.
  The target video itself is excluded.

  Returns an empty list for movies or videos without a recognisable
  season folder structure.
  """
  @spec sibling_vmaf_records(Video.t() | map()) :: [{float(), float()}]
  def sibling_vmaf_records(%{id: video_id, path: path, height: height, width: width, hdr: hdr}) do
    season_dir = Path.dirname(path)

    if season_folder?(season_dir) do
      query_sibling_vmaf_records(video_id, season_dir, height, width, hdr)
    else
      []
    end
  end

  def sibling_vmaf_records(_video), do: []

  @doc """
  Returns true if the given CRF range is narrower than the default `{5, 70}`.
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

  defp query_sibling_vmaf_records(exclude_video_id, season_dir, height, width, hdr) do
    dir_prefix = season_dir <> "/"

    base_query =
      from v in Video,
        join: vmaf in Vmaf,
        on: vmaf.video_id == v.id,
        where: v.id != ^exclude_video_id,
        where: like(v.path, ^"#{dir_prefix}%"),
        where: v.height == ^height,
        where: v.width == ^width,
        where: v.chosen_vmaf_id == vmaf.id,
        select: {vmaf.crf, vmaf.score}

    query =
      if is_nil(hdr) do
        from [v, _vmaf] in base_query, where: is_nil(v.hdr)
      else
        from [v, _vmaf] in base_query, where: not is_nil(v.hdr)
      end

    Repo.all(query)
  end

  # Given {crf, score} pairs and a target, compute the tightest valid bracket.
  #
  # - Highest-CRF passing record  → floor  (min_crf = that CRF − margin)
  # - Lowest-CRF  failing record  → ceiling (max_crf = that CRF + margin)
  # - Only passing → ceiling = highest_passing_crf + margin * 2 (also search above)
  # - Only failing → floor = @absolute_min_crf (go as low as needed)
  defp bracket_range(records, target, margin) do
    passing = Enum.filter(records, fn {_crf, score} -> score >= target end)
    failing = Enum.filter(records, fn {_crf, score} -> score < target end)

    min_crf =
      case passing do
        [] ->
          @absolute_min_crf

        ps ->
          highest_passing = ps |> Enum.max_by(&elem(&1, 0)) |> elem(0)
          max(@absolute_min_crf, floor(highest_passing) - margin)
      end

    max_crf =
      case failing do
        [] ->
          # No failing data — also search a bit above the highest passing CRF
          case passing do
            [] ->
              @absolute_max_crf

            ps ->
              highest_passing = ps |> Enum.max_by(&elem(&1, 0)) |> elem(0)
              min(@absolute_max_crf, ceil(highest_passing) + margin * 2)
          end

        fs ->
          lowest_failing = fs |> Enum.min_by(&elem(&1, 0)) |> elem(0)
          min(@absolute_max_crf, ceil(lowest_failing) + margin)
      end

    {min_crf, max_crf}
  end
end
