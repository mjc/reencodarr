import Ecto.Query

# Get all videos with chosen VMAF results
query = from v in Reencodarr.Media.Video,
  join: vmaf in Reencodarr.Media.Vmaf, on: vmaf.video_id == v.id,
  where: v.chosen_vmaf_id == vmaf.id,
  select: %{path: v.path, bitrate: v.bitrate, crf: vmaf.crf, width: v.width, height: v.height, hdr: v.hdr}

raw_results = Reencodarr.Repo.all(query)

# Extract series name and season from path
# Paths look like: /path/to/Series Name/Season 01/Episode.mkv
# or: /path/to/Series Name (Year)/Season 01/Episode.mkv
extract_series_info = fn path ->
  parts = String.split(path, "/")

  # Find the season folder and get series name from one folder up
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

results = raw_results
|> Enum.map(fn r ->
  case extract_series_info.(r.path) do
    {series, season} -> Map.merge(r, %{series: series, season: season})
    nil -> nil
  end
end)
|> Enum.reject(&is_nil/1)

IO.puts("Total TV episodes with CRF results: #{length(results)}\n")

data = results
|> Enum.group_by(fn r -> {r.series, r.season} end)
|> Enum.filter(fn {_, eps} -> length(eps) >= 4 end)
|> Enum.sort_by(fn {key, _} -> key end)

IO.puts("Seasons with 4+ episodes: #{length(data)}\n")
IO.puts(String.duplicate("=", 100))

Enum.each(data, fn {{series, season}, episodes} ->
  crfs = Enum.map(episodes, & &1.crf)
  bitrates = episodes |> Enum.map(& &1.bitrate) |> Enum.reject(&is_nil/1) |> Enum.map(& &1 / 1_000_000)

  avg_crf = Float.round(Enum.sum(crfs) / length(crfs), 1)
  min_crf = Enum.min(crfs)
  max_crf = Enum.max(crfs)
  range = Float.round(max_crf - min_crf, 1)
  std_dev = :math.sqrt(Enum.sum(Enum.map(crfs, fn c -> :math.pow(c - avg_crf, 2) end)) / length(crfs)) |> Float.round(2)

  br_str = if bitrates != [] do
    avg_br = Float.round(Enum.sum(bitrates) / length(bitrates), 1)
    min_br = Float.round(Enum.min(bitrates), 1)
    max_br = Float.round(Enum.max(bitrates), 1)
    br_range = Float.round(max_br - min_br, 1)
    "BR: #{min_br}-#{max_br} (avg #{avg_br}, Δ#{br_range}) Mbps"
  else
    "BR: N/A"
  end

  # Truncate series name for display
  short_name = if String.length(series) > 30, do: String.slice(series, 0, 27) <> "...", else: series

  IO.puts("#{String.pad_trailing(short_name, 30)} S#{String.pad_leading(to_string(season), 2, "0")} (#{String.pad_leading(to_string(length(episodes)), 2)} eps) | CRF #{String.pad_leading(to_string(min_crf), 4)}-#{String.pad_trailing(to_string(max_crf), 4)} avg #{String.pad_leading(to_string(avg_crf), 4)} σ#{String.pad_leading(to_string(std_dev), 4)} | #{br_str}")
end)

IO.puts(String.duplicate("=", 100))

# Compute overall statistics
all_ranges = Enum.map(data, fn {_, episodes} ->
  crfs = Enum.map(episodes, & &1.crf)
  Enum.max(crfs) - Enum.min(crfs)
end)

avg_range = Float.round(Enum.sum(all_ranges) / length(all_ranges), 2)
median_range = Enum.sort(all_ranges) |> Enum.at(div(length(all_ranges), 2)) |> Float.round(2)
tight_seasons = Enum.count(all_ranges, & &1 <= 3.0)
pct_tight = Float.round(tight_seasons / length(all_ranges) * 100, 1)

IO.puts("\nSUMMARY (ALL SEASONS):")
IO.puts("  Average CRF range within a season: #{avg_range}")
IO.puts("  Median CRF range within a season: #{median_range}")
IO.puts("  Seasons with CRF range <= 3: #{tight_seasons}/#{length(data)} (#{pct_tight}%)")

# NOW FILTER: Only seasons where bitrate variation is low (rel std dev < 15%)
IO.puts("\n" <> String.duplicate("=", 100))
IO.puts("ANALYSIS: SEASONS WITH CONSISTENT BITRATES (bitrate std dev < 10%)")
IO.puts(String.duplicate("=", 100))

consistent_br_data = data
|> Enum.filter(fn {_, episodes} ->
  bitrates = episodes |> Enum.map(& &1.bitrate) |> Enum.reject(&is_nil/1) |> Enum.reject(&(&1 == 0))

  if length(bitrates) >= 4 do
    avg = Enum.sum(bitrates) / length(bitrates)
    std = :math.sqrt(Enum.sum(Enum.map(bitrates, fn b -> :math.pow(b - avg, 2) end)) / length(bitrates))
    rel_std = std / avg
    rel_std < 0.10  # Less than 10% relative standard deviation
  else
    false
  end
end)

Enum.each(consistent_br_data, fn {{series, season}, episodes} ->
  crfs = Enum.map(episodes, & &1.crf)
  bitrates = episodes |> Enum.map(& &1.bitrate) |> Enum.reject(&is_nil/1) |> Enum.reject(&(&1 == 0)) |> Enum.map(& &1 / 1_000_000)

  avg_crf = Float.round(Enum.sum(crfs) / length(crfs), 1)
  min_crf = Enum.min(crfs)
  max_crf = Enum.max(crfs)
  crf_range = Float.round(max_crf - min_crf, 1)
  std_dev = :math.sqrt(Enum.sum(Enum.map(crfs, fn c -> :math.pow(c - avg_crf, 2) end)) / length(crfs)) |> Float.round(2)

  avg_br = Float.round(Enum.sum(bitrates) / length(bitrates), 1)
  br_std = :math.sqrt(Enum.sum(Enum.map(bitrates, fn b -> :math.pow(b - avg_br, 2) end)) / length(bitrates)) |> Float.round(2)

  short_name = if String.length(series) > 30, do: String.slice(series, 0, 27) <> "...", else: series

  IO.puts("#{String.pad_trailing(short_name, 30)} S#{String.pad_leading(to_string(season), 2, "0")} (#{String.pad_leading(to_string(length(episodes)), 2)} eps) | CRF #{String.pad_leading(to_string(min_crf), 4)}-#{String.pad_trailing(to_string(max_crf), 4)} Δ#{String.pad_leading(to_string(crf_range), 4)} σ#{String.pad_trailing(to_string(std_dev), 4)} | BR #{avg_br}±#{br_std} Mbps")
end)

consistent_ranges = Enum.map(consistent_br_data, fn {_, eps} ->
  crfs = Enum.map(eps, & &1.crf)
  Enum.max(crfs) - Enum.min(crfs)
end)

if length(consistent_ranges) > 0 do
  avg_r = Float.round(Enum.sum(consistent_ranges) / length(consistent_ranges), 2)
  med_r = Enum.sort(consistent_ranges) |> Enum.at(div(length(consistent_ranges), 2)) |> Float.round(2)
  tight = Enum.count(consistent_ranges, & &1 <= 3.0)
  very_tight = Enum.count(consistent_ranges, & &1 <= 5.0)
  pct = Float.round(tight / length(consistent_ranges) * 100, 1)
  pct5 = Float.round(very_tight / length(consistent_ranges) * 100, 1)

  IO.puts("\nSUMMARY (CONSISTENT BITRATE SEASONS ONLY):")
  IO.puts("  Seasons analyzed: #{length(consistent_br_data)}")
  IO.puts("  Average CRF range: #{avg_r}")
  IO.puts("  Median CRF range: #{med_r}")
  IO.puts("  Seasons with CRF range <= 3: #{tight}/#{length(consistent_br_data)} (#{pct}%)")
  IO.puts("  Seasons with CRF range <= 5: #{very_tight}/#{length(consistent_br_data)} (#{pct5}%)")
else
  IO.puts("No seasons with consistent bitrate found")
end
