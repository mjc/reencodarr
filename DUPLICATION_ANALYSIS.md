# Reencodarr Codebase Duplication Analysis
**Last Updated:** August 21, 2025

## Executive Summary

After comprehensive analysis of the current codebase, significant duplication exists across **15+ major patterns** affecting **35+ files**. The codebase has grown organically with multiple formatter modules, test helper variations, and repeated validation patterns. **Estimated reduction potential: 1,200-1,800 lines** of duplicated code.

## Top 12 Duplication Patterns (Ranked by Impact)

### 1. **File Size Formatting Explosion** ✅ **RESOLVED**
**Files Affected:** 12+ files  
**Duplication Level:** ~~CRITICAL~~ → **FIXED**

~~Multiple independent implementations of byte-to-human formatting with different conversion logic~~

**RESOLUTION COMPLETED:**
- ✅ Consolidated into unified `Reencodarr.Formatters` module
- ✅ Removed duplicate implementations from `failures_live.ex`
- ✅ Updated delegation in `core/formatters.ex`
- ✅ Standardized on binary prefixes (KiB, MiB, GiB, TiB)
- ✅ Comprehensive test coverage with edge case handling
- ✅ Backward compatibility maintained

**Files Cleaned:**
- `lib/reencodarr/formatters.ex` - Now single source of truth
- `lib/reencodarr_web/live/failures_live.ex` - Uses unified formatter
- `lib/reencodarr/core/formatters.ex` - Proper delegation
- `test/reencodarr/formatters_test.exs` - Consolidated test coverage

### 2. **Test Fixture Factory Proliferation** ⭐⭐⭐⭐⭐
**Files Affected:** 18+ test files
**Duplication Level:** CRITICAL

Multiple incompatible test fixture systems with overlapping functionality:

**Duplicate Systems:**
- `test/support/fixtures.ex` - 500+ lines, comprehensive fixtures
- `test/support/fixtures/media_fixtures.ex` - 250+ lines, overlapping functionality
- Inline `video_fixture()` definitions in 15+ test files
- Multiple `create_video`, `video_with_vmaf`, `encoding_scenario` variations

**Common Duplicated Patterns:**
```elixir
# Found in 18+ files:
def video_fixture(attrs \\ %{}) do
  defaults = %{
    bitrate: 5_000_000,
    size: 2_000_000_000,
    reencoded: false,
    failed: false
  }
  # Same merge logic everywhere
end
```

### 3. **Validation Pattern Redundancy** ⭐⭐⭐⭐⭐
**Files Affected:** 10+ schemas
**Duplication Level:** CRITICAL

Changeset validation patterns repeated across schemas:

**Key Files:**
- `lib/reencodarr/changeset_helpers.ex` - Centralized but underused
- `lib/reencodarr/validation.ex` - Overlapping with changeset_helpers
- Multiple MediaInfo schema modules with duplicate validation
- Test support modules with validation assertions

**Repeated Patterns:**
```elixir
# Same validation logic in 10+ places:
def validate_positive_number(changeset, field) do
  value = get_field(changeset, field)
  if is_number(value) and value <= 0 do
    add_error(changeset, field, "must be positive")
  else
    changeset
  end
end
```

### 4. **Test Helper Assertion Duplication** ⭐⭐⭐⭐⭐
**Files Affected:** 15+ test files
**Duplication Level:** CRITICAL

Inconsistent test assertion helpers across test files:

**Key Files:**
- `test/support/test_helpers.ex` - Comprehensive helpers
- `test/support/data_case.ex` - Overlapping `assert_ok`, `assert_error`
- Inline helper definitions in 15+ test files

**Duplicated Assertions:**
```elixir
# Found in 15+ test files:
def assert_video_attributes(video, expected_attrs) do
  Enum.each(expected_attrs, fn {key, expected_value} ->
    actual_value = Map.get(video, key)
    assert actual_value == expected_value
  end)
end

# Repeated flag-finding logic:
def find_flag_indices(args, flag) do
  args
  |> Enum.with_index()
  |> Enum.filter(fn {arg, _} -> arg == flag end)
  |> Enum.map(&elem(&1, 1))
end
```

### 5. **Numeric Parsing Fragmentation** ⭐⭐⭐⭐
**Files Affected:** 8+ files
**Duplication Level:** HIGH

Multiple numeric parsing implementations with different edge case handling:

**Key Files:**
- `lib/reencodarr/numeric_parser.ex` - Centralized but specific use
- `lib/reencodarr/data_converters.ex` - Overlapping `parse_numeric`
- `lib/reencodarr/core/parsers.ex` - More overlapping parsing
- MediaInfo modules with inline parsing

**The Problem:**
```elixir
# 3+ different implementations:
def parse_numeric(value) when is_binary(value) do
  cleaned = String.replace(value, ~r/[^\d.]/, "")
  case Float.parse(cleaned) do
    {float_val, ""} -> float_val
    _ -> 0.0
  end
end
```

### 6. **Regex Pattern Proliferation** ⭐⭐⭐⭐
**Files Affected:** 8+ files
**Duplication Level:** HIGH

Complex regex parsing with repeated extraction patterns:

**Key Files:**
- `lib/reencodarr/ab_av1/output_parser.ex` - Centralized patterns with field mappings
- `lib/reencodarr/ab_av1/crf_search.ex` - Overlapping pattern definitions
- `lib/reencodarr/progress_parser.ex` - Similar parsing structure
- Multiple test files with pattern matching

**Common Structure:**
```elixir
# Same extraction pattern in 8+ files:
case Regex.named_captures(pattern, line) do
  nil -> nil
  captures -> %{
    field: parse_type(captures["field"]),
    value: captures["value"]
  }
end
```

### 7. **Time/Duration Formatting Scattered** ⭐⭐⭐⭐
**Files Affected:** 6+ files
**Duplication Level:** HIGH

Multiple duration formatting approaches:

**Key Files:**
- `lib/reencodarr/core/formatters.ex` - `format_duration/1`
- `lib/reencodarr/progress_parser.ex` - `format_eta/2`
- `lib/reencodarr_web/utils/time_utils.ex` - Complex time formatting
- LiveView components with inline duration logic

### 8. **CSS Button Class Patterns** ⭐⭐⭐⭐
**Files Affected:** 8+ LiveView files
**Duplication Level:** HIGH

Repeated button styling patterns across LiveViews:

**Pattern in Multiple Files:**
```elixir
# Repeated in 8+ LiveView files:
class={"px-3 py-1 text-xs rounded transition-colors " <>
       if(@filter == "value", do: "bg-orange-500 text-black", 
          else: "bg-gray-700 text-orange-400 hover:bg-orange-600")}
```

### 9. **Error Handling Patterns** ⭐⭐⭐⭐
**Files Affected:** 10+ modules
**Duplication Level:** HIGH

Repeated error handling and changeset error patterns:

**Common Pattern:**
```elixir
# Found in 10+ places:
case operation() do
  {:ok, result} -> result
  {:error, changeset} -> 
    Logger.error("Operation failed: #{inspect(changeset.errors)}")
    {:error, changeset}
end
```

### 10. **Media Format Detection Logic** ⭐⭐⭐
**Files Affected:** 6+ files
**Duplication Level:** MEDIUM-HIGH

Codec detection and format logic scattered:

**Key Files:**
- `lib/reencodarr/media/codecs.ex` - Centralized codec helpers
- Multiple MediaInfo conversion modules
- LiveView formatting with inline codec logic

### 11. **Resolution Parsing Redundancy** ⭐⭐⭐
**Files Affected:** 5+ files
**Duplication Level:** MEDIUM

Resolution parsing logic repeated:

**Duplicate Pattern:**
```elixir
# Found in 5+ files:
def parse_resolution(resolution_string) do
  case String.split(resolution_string, "x") do
    [width_str, height_str] ->
      {String.to_integer(width_str), String.to_integer(height_str)}
    _ -> {0, 0}
  end
end
```

### 12. **Miscellaneous Pipeline Utilities** ⭐⭐⭐
**Files Affected:** 5+ files
**Duplication Level:** MEDIUM

Scattered utility functions across pipeline modules with similar functionality - could benefit from shared utilities module, but lower priority.

---

## ✅ **COMPLETED DEDUPLICATION FIXES**

### **Formatter Test Consolidation** (August 2025)
**Impact:** 3 duplicate test files eliminated, 150+ lines of duplicate test code removed

**Files Removed:**
- `test/reencodarr/format_helpers_test.exs` (duplicate file size tests)
- `test/reencodarr/liveview_helpers_consolidation_test.exs` (duplicate formatter tests)
- `test/reencodarr_web/dashboard_savings_format_test.exs` (duplicate savings format tests)

**Created:**
- `test/reencodarr/formatters_test.exs` - Comprehensive, unified test coverage

**Benefits Achieved:**
- ✅ Single source of truth for formatter testing
- ✅ Consistent binary prefix usage (KiB, MiB, GiB, TiB)
- ✅ Comprehensive edge case coverage
- ✅ 150+ lines of duplicate test code eliminated
- ✅ No more conflicting test expectations

### **Core.Formatters Elimination** (August 2025)
**Impact:** Unused dead code module removed, duration formatting improved

**Files Removed:**
- `lib/reencodarr/core/formatters.ex` (unused dead code with duplicated functions)

**Functions Migrated:**
- Enhanced `format_duration/1` with detailed "1h 1m 1s" format
- Added `normalize_string/1` function to main Formatters module

**Benefits Achieved:**
- ✅ Eliminated unused module with duplicate functionality
- ✅ Improved duration formatting precision ("1h 1m 1s" instead of "1h 1m")
- ✅ Added useful string normalization utility
- ✅ 97 lines of duplicate/dead code removed
- ✅ No more confusion between formatting modules

---

## Estimated Impact

## New Issues Not Previously Identified

### Critical Findings:

1. **Multiple Formatter Modules:** Three separate formatting modules (`Reencodarr.Formatters`, `Reencodarr.Core.Formatters`, web formatters) with overlapping functionality

2. **Test Fixture Chaos:** Two major fixture systems (`fixtures.ex` and `fixtures/media_fixtures.ex`) with 70%+ overlap and inconsistent APIs

3. **Validation Logic Spread:** Validation helpers exist in 4+ places with different patterns and inconsistent error handling

4. **CSS Utility Duplication:** Button classes and LCARS styling patterns repeated across 8+ LiveView files

5. **Parsing Function Explosion:** 15+ parsing functions across modules for similar data types (numeric, duration, resolution)

## Recommended Consolidation Strategy

### Phase 1: Critical Consolidation (Week 1)
1. **Unify File Size Formatting:** Single module with comprehensive functions
2. **Consolidate Test Fixtures:** Merge fixture systems into unified API
3. **Standardize Validation:** Central validation with consistent error handling
4. **Consolidate Test Helpers:** Single comprehensive test helper module

### Phase 2: Major Cleanup (Week 2)
1. **Regex Pattern Consolidation:** Central parsing utility with field mapping
2. **CSS Utility Module:** Shared component classes and utility functions
3. **Numeric Parsing Unification:** Single robust parsing module
4. **Time/Duration Standardization:** Unified time formatting utilities

### Phase 3: Final Polish (Week 3)
1. **Database Query Patterns:** Shared query utilities
2. **Error Handling Standardization:** Consistent error patterns
3. **Update All References:** Point to consolidated modules
4. **Remove Deprecated Code:** Clean up old implementations

## Estimated Impact

**Lines of Code Reduction:** 1,200-1,800 lines (significantly higher than original estimate)  
**Files Affected:** 35+ files (40% more than originally identified)  
**Maintenance Improvement:** CRITICAL - Multiple sources of truth eliminated  
**Bug Risk Reduction:** HIGH - Inconsistent implementations eliminated  
**Developer Experience:** Significant improvement with unified APIs  

## Files Requiring Major Changes

### Critical Priority
- `lib/reencodarr/formatters.ex` - Consolidate with other formatters
- `test/support/fixtures.ex` - Merge with media_fixtures.ex
- `lib/reencodarr/validation.ex` - Merge with changeset_helpers.ex
- `test/support/test_helpers.ex` - Expand and consolidate all test utilities

### High Priority
- 8+ LiveView files - Extract CSS utilities
- 15+ test files - Standardize on unified fixtures
- MediaInfo modules - Use central validation/parsing
- Multiple parsing modules - Consolidate numeric/time parsing

### Medium Priority
- Context modules - Standardize query patterns
- Error handling - Unified error response patterns
- Web components - Extract shared UI utilities

## Action Items for Implementation

1. **Immediate:** Audit and catalog all file size formatting functions
2. **Week 1:** Create unified `Reencodarr.FormatHelpers` module
3. **Week 1:** Merge test fixture systems with migration guide
4. **Week 2:** Create `Reencodarr.ParseHelpers` for all parsing needs
5. **Week 2:** Extract shared CSS utilities to component module
6. **Week 3:** Update all references and remove deprecated modules

This analysis reveals the duplication problem is **significantly more extensive** than previously documented, requiring systematic refactoring across the entire codebase.
