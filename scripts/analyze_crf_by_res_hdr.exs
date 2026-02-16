import Ecto.Query

# Get all videos with chosen VMAF results
query = from v in Reencodarr.Media.Video,
  join: vmaf in Reencodarr.Media.Vmaf, on: vmaf.video_id == v.id,
  where: vmaf.chosen == true,
  select: %{
    path: v.path,
    bitrate: v.bitrate,
    crf: vmaf.crf,
    width: v.width,
    height: v.height,
    hdr: v.hdr
  }

raw_results = Reencodarr.Repo.all(query)

# Extract series name and season from path
extract_series_info = fn path ->
  parts = String.split(path, "/")
  
  Enum.with_index(parts)
  |> Enum.find_value(fn {part, idx} ->
    case Regex.run(~r/^[Ss](?:eason\s*)?0*(\d+)$/i, part) do
      [_, season_num] when idx > 0 ->
        series = Enum.at(parts, idx - 1)
        {series, String.to_integer(season_num)}
      _ -> nil
    end
  end)
end

# Normalize resolution to standard buckets
normalize_res = fn width, height ->
  cond do
    height >= 2160 or width >= 3840 -> "4K"
    height >= 1080 or width >= 1920 -> "1080p"
    height >= 720 or width >= 1280 -> "720p"
    height >= 480 or width >= 854 -> "480p"
    true -> "SD"
  end
end

# Normalize HDR
normalize_hdr = fn hdr ->
  cond do
    is_nil(hdr) or hdr == "" -> "SDR"
    true -> "HDR"
  end
end

results = raw_results
|> Enum.map(fn r ->
  case extract_series_info.(r.path) do
    {series, season} -> 
      Map.merge(r, %{
        series: series, 
        season: season,
        resolution: normalize_res.(r.width, r.height),
        hdr_status: normalize_hdr.(r.hdr)
      })
    nil -> nil
  end
end)
|> Enum.reject(&is_nil/1)

IO.puts(String.duplicate("=", 110))
IO.puts("ANALYSIS: CRF VARIANCE BY SERIES + SEASON + RESOLUTION + HDR")
IO.puts(String.duplicate("=", 110))
IO.puts("Question: If we know the CRF for one episode, can we narrow the search range for subsequent episodes?")
IO.puts(String.duplicate("=", 110) <> "\n")

# Group by series + season + resolution + HDR
grouped = results
|> Enum.group_by(fn r -> {r.series, r.season, r.resolution, r.hdr_status} end)
|> Enum.filter(fn {_, eps} -> length(eps) >= 3 end)
|> Enum.sort_by(fn {{series, season, _, _}, _} -> {series, season} end)

IO.puts("Groups with 3+ episodes (same series/season/resolution/hdr): #{length(grouped)}\n")

# Calculate stats for each group
stats = Enum.map(grouped, fn {{series, season, res, hdr}, episodes} ->
  crfs = Enum.map(episodes, & &1.crf)
  min_crf = Enum.min(crfs)
  max_crf = Enum.max(crfs)
  range = max_crf - min_crf
  avg_crf = Enum.sum(crfs) / length(crfs)
  std_dev = :math.sqrt(Enum.sum(Enum.map(crfs, fn c -> :math.pow(c - avg_crf, 2) end)) / length(crfs))
  
  %{
    series: series,
    season: season,
    res: res,
    hdr: hdr,
    count: length(episodes),
    min: min_crf,
    max: max_crf,
    range: range,
    avg: avg_crf,
    std: std_dev
  }
end)

# Print detailed results
Enum.each(stats, fn s ->
  short_name = if String.length(s.series) > 28, do: String.slice(s.series, 0, 25) <> "...", else: s.series
  
  IO.puts("#{String.pad_trailing(short_name, 28)} S#{String.pad_leading(to_string(s.season), 2, "0")} #{String.pad_trailing(s.res, 5)} #{String.pad_trailing(s.hdr, 3)} (#{String.pad_leading(to_string(s.count), 2)} eps) | CRF #{String.pad_leading(to_string(s.min), 4)}-#{String.pad_trailing(to_string(s.max), 4)} Δ#{String.pad_leading(Float.to_string(Float.round(s.range, 1)), 4)} σ#{Float.round(s.std, 1)}")
end)

IO.puts("\n" <> String.duplicate("=", 110))
IO.puts("SUMMARY STATISTICS")
IO.puts(String.duplicate("=", 110))

ranges = Enum.map(stats, & &1.range)
stds = Enum.map(stats, & &1.std)

avg_range = Float.round(Enum.sum(ranges) / length(ranges), 2)
median_range = Enum.sort(ranges) |> Enum.at(div(length(ranges), 2)) |> Float.round(2)
avg_std = Float.round(Enum.sum(stds) / length(stds), 2)

within_3 = Enum.count(ranges, & &1 <= 3)
within_5 = Enum.count(ranges, & &1 <= 5)
within_7 = Enum.count(ranges, & &1 <= 7)
within_10 = Enum.count(ranges, & &1 <= 10)

pct_3 = Float.round(within_3 / length(ranges) * 100, 1)
pct_5 = Float.round(within_5 / length(ranges) * 100, 1)
pct_7 = Float.round(within_7 / length(ranges) * 100, 1)
pct_10 = Float.round(within_10 / length(ranges) * 100, 1)

IO.puts("\nTotal groups analyzed: #{length(stats)}")
IO.puts("Average CRF range: #{avg_range}")
IO.puts("Median CRF range: #{median_range}")
IO.puts("Average CRF std dev: #{avg_std}")
IO.puts("")
IO.puts("Groups with CRF range ≤ 3:  #{within_3}/#{length(stats)} (#{pct_3}%)")
IO.puts("Groups with CRF range ≤ 5:  #{within_5}/#{length(stats)} (#{pct_5}%)")
IO.puts("Groups with CRF range ≤ 7:  #{within_7}/#{length(stats)} (#{pct_7}%)")
IO.puts("Groups with CRF range ≤ 10: #{within_10}/#{length(stats)} (#{pct_10}%)")

# PRACTICAL RECOMMENDATION
IO.puts("\n" <> String.duplicate("=", 110))
IO.puts("PRACTICAL IMPLICATION")
IO.puts(String.duplicate("=", 110))

# If we find CRF X for ep 1, what range could we search for ep 2?
# Based on observed std devs, ±2σ would cover ~95% of cases
p95_range = Float.round(avg_std * 2, 1)
p99_range = Float.round(avg_std * 3, 1)

IO.puts("""

If episode 1 of a season finds CRF = X, for subsequent episodes with same resolution/HDR:
  
  95% confidence: Search CRF range = X ± #{p95_range} (based on 2σ)
  99% confidence: Search CRF range = X ± #{p99_range} (based on 3σ)

Example: If ep 1 finds CRF 20, search ep 2-N in range #{20 - trunc(p95_range)}-#{20 + trunc(p95_range)} instead of default 10-55
This could reduce search iterations by ~50%+ for subsequent episodes.
""")

# Distribution analysis
IO.puts("\nCRF RANGE DISTRIBUTION:")
buckets = [
  {0, 2, "0-2"},
  {2, 4, "2-4"},
  {4, 6, "4-6"},
  {6, 8, "6-8"},
  {8, 10, "8-10"},
  {10, 15, "10-15"},
  {15, 20, "15-20"},
  {20, 100, "20+"}
]

Enum.each(buckets, fn {lo, hi, label} ->
  count = Enum.count(ranges, fn r -> r >= lo and r < hi end)
  pct = Float.round(count / length(ranges) * 100, 1)
  bar = String.duplicate("█", trunc(pct / 2))
  IO.puts("  #{String.pad_leading(label, 5)}: #{String.pad_leading(to_string(count), 3)} (#{String.pad_leading(Float.to_string(pct), 5)}%) #{bar}")
end)
