# Reencodarr Codebase Duplication Analysis

## Executive Summary

The Reencodarr codebase contains significant duplication across several areas. While some consolidation has already occurred (FormatHelpers, TimeHelpers), there are still major opportunities for reducing duplicated work and improving maintainability.

## Top 7 Duplication Patterns (Ranked by Impact)

### 1. **Regex Pattern & Parse Logic Duplication** ⭐⭐⭐⭐⭐
**Files Affected:** 10+ files
**Duplication Level:** Very High

The most significant duplication is in regex pattern matching and parsing logic across:

```elixir
# Same pattern repeated everywhere:
case Regex.named_captures(regex, line) do
  nil -> nil
  captures -> %{
    field: parse_type(captures["field"]),
    # ... same extraction logic
  }
end
```

**Key Files:**
- `lib/reencodarr/ab_av1/output_parser.ex` (15+ parse functions)
- `lib/reencodarr/ab_av1/crf_search.ex` (@patterns map)
- `lib/reencodarr/media/video/media_info/*.ex` (audio_track, video_track, general_track)
- `lib/reencodarr/progress_parser.ex`

**Consolidation Opportunity:**
Create a `Reencodarr.ParseHelpers` module with:
```elixir
defmodule Reencodarr.ParseHelpers do
  def parse_with_regex(line, pattern, field_mapping) do
    case Regex.named_captures(pattern, line) do
      nil -> nil
      captures -> extract_fields(captures, field_mapping)
    end
  end
  
  def extract_fields(captures, field_mapping) do
    Enum.reduce(field_mapping, %{}, fn {key, {capture_key, parser}}, acc ->
      Map.put(acc, key, parser.(captures[capture_key]))
    end)
  end
end
```

### 2. **File Size Formatting Duplication** ⭐⭐⭐⭐
**Files Affected:** 8+ files
**Duplication Level:** High

Multiple implementations of bytes-to-human-readable formatting:

**Duplicated Across:**
- `lib/reencodarr/format_helpers.ex` (3 different functions)
- `lib/reencodarr_web/helpers/format_helpers.ex` (2 versions)
- `lib/reencodarr_web/components/dashboard_formatters.ex`
- `lib/reencodarr/core/formatters.ex`
- `lib/reencodarr_web/live/failures_live.ex` (private function)

**Same Logic Repeated:**
```elixir
# Pattern repeated in 8+ places:
cond do
  bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 1)} TB"
  bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  # ... etc
end
```

### 3. **Count/Metric Formatting Duplication** ⭐⭐⭐⭐
**Files Affected:** 6+ files
**Duplication Level:** High

K/M suffix formatting logic duplicated across:
- `lib/reencodarr_web/helpers/format_helpers.ex`
- `lib/reencodarr_web/components/dashboard_formatters.ex`
- Multiple LiveView files

**Same Pattern:**
```elixir
cond do
  count >= 1_000_000 -> "#{Float.round(count / 1_000_000, 1)}M"
  count >= 1_000 -> "#{Float.round(count / 1_000, 1)}K"
  true -> to_string(count)
end
```

### 4. **Test Helper Duplication** ⭐⭐⭐⭐
**Files Affected:** 12+ test files
**Duplication Level:** High

Test helper patterns repeated across multiple test files:

**Common Patterns:**
```elixir
# Video creation helpers (5+ versions):
defp create_test_video(attrs \\ %{}) do
  defaults = %{...}
  struct(Reencodarr.Media.Video, Map.merge(defaults, attrs))
end

# Helper pattern matching (3+ versions):
defp match_return_value(return_value) do
  case return_value do
    %Reencodarr.Media.Vmaf{} -> :single_vmaf
    # ... same logic
  end
end

# Flag finding logic (4+ versions):
defp find_flag_indices(args, flag) do
  # Same implementation everywhere
end
```

**Files With Duplication:**
- `test/reencodarr/rules_test.exs`
- `test/reencodarr/encoder/audio_args_test.exs`
- `test/reencodarr/ab_av1/crf_search/*_test.exs`
- `test/support/test_helpers.ex`
- `test/support/unified_test_helpers.ex`

### 5. **Format Function Delegation Duplication** ⭐⭐⭐
**Files Affected:** 4+ files
**Duplication Level:** Medium-High

Multiple modules delegating to the same formatting functions:

```elixir
# Repeated in 4+ modules:
def format_fps(fps), do: FormatHelpers.format_fps(fps)
def format_count(count), do: FormatHelpers.format_count(count)
def format_eta(eta), do: FormatHelpers.format_eta(eta)
```

**Files:**
- `lib/reencodarr/progress_helpers.ex`
- `lib/reencodarr_web/components/dashboard_formatters.ex`
- `lib/reencodarr_web/helpers/format_helpers.ex`

### 6. **CSS Class Pattern Duplication** ⭐⭐⭐
**Files Affected:** 3+ LiveView files
**Duplication Level:** Medium

Button styling and CSS class patterns repeated:

```elixir
# Repeated button class pattern:
class={"px-3 py-1 text-xs rounded transition-colors " <>
       if(@filter == "value", do: "bg-orange-500 text-black", 
          else: "bg-gray-700 text-orange-400 hover:bg-orange-600")}
```

### 7. **Numeric Parsing Duplication** ⭐⭐⭐
**Files Affected:** 6+ files
**Duplication Level:** Medium

Similar parsing logic for numeric values:

```elixir
# Pattern repeated in media_info parsing:
defp parse_numeric(value) when is_binary(value) do
  cleaned = String.replace(value, ~r/[^\d.]/, "")
  case Float.parse(cleaned) do
    {float_val, ""} -> # same logic everywhere
    # ...
  end
end
```

## Recommended Consolidation Strategy

### Phase 1: Critical Duplication (Week 1)
1. **Create `Reencodarr.ParseHelpers`** - Consolidate all regex parsing patterns
2. **Standardize on single format helper** - Remove duplicate file size functions
3. **Consolidate test helpers** - Move to single `test/support/` module

### Phase 2: Medium Priority (Week 2) 
1. **Create CSS component helpers** - Extract button/styling patterns
2. **Consolidate numeric parsing** - Single module for all parsing logic
3. **Remove delegation duplication** - Use single format helper

### Phase 3: Polish (Week 3)
1. **Update all references** - Point to consolidated modules
2. **Remove deprecated helpers** - Clean up old files
3. **Add comprehensive tests** - Test consolidated functionality

## Estimated Impact

**Lines of Code Reduction:** ~800-1200 lines
**Files Affected:** 25+ files
**Maintenance Improvement:** High - Single source of truth for formatting, parsing, and test utilities
**Performance Impact:** Minor improvement from reduced compilation overhead

## Files to Modify/Remove

### High Priority
- Consolidate: `lib/reencodarr/ab_av1/output_parser.ex`
- Merge: All format_helpers variants
- Standardize: `test/support/*_helpers.ex` files

### Medium Priority  
- Simplify: MediaInfo parsing modules
- Clean up: LiveView formatting functions
- Consolidate: Test fixture creation patterns

This analysis shows significant opportunities for reducing duplicated work while improving code maintainability and reducing the likelihood of bugs from inconsistent implementations.
