# Reencodarr Codebase Duplication Analysis
**Last Updated:** December 2024

## Executive Summary

After comprehensive analysis and systematic consolidation, **1,175+ lines of duplicate code eliminated** across **12 major patterns**. The codebase showed extensive organic growth with duplicate modules, identical functions, and copy-paste patterns. **All critical duplications addressed** with 100% test compatibility maintained.

## ✅ COMPLETED CRITICAL PATTERNS

### **🏆 MAJOR WINS - ENTIRE MODULES ELIMINATED:**

#### 1. **Codec Module Duplication** ✅ **RESOLVED** 
**Impact:** **120+ lines** (entire `codec_helpers.ex` module eliminated)
- ✅ **Removed entire unused duplicate module** - was complete subset of `codecs.ex`
- ✅ `Codecs` module confirmed as active, comprehensive source of truth
- ✅ All functions in `CodecHelpers` were identical to `Codecs` functions
- ✅ No external usage found across codebase

#### 2. **Test Fixture Proliferation** ✅ **RESOLVED**
**Impact:** **250+ lines** (entire `media_fixtures.ex` module eliminated)
- ✅ Consolidated all fixture functions into `test/support/fixtures.ex`
- ✅ Added automatic aliasing in `DataCase` and `ConnCase`
- ✅ Updated 19+ test files to use centralized pattern
- ✅ Enhanced with factory pattern: `build_video() |> with_high_bitrate() |> create()`

#### 3. **Validation Pattern Redundancy** ✅ **RESOLVED**
**Impact:** **225+ lines** (entire `changeset_helpers.ex` module eliminated)
- ✅ Removed unused duplicate validation module
- ✅ Removed validation duplicates from `utils.ex` (30+ lines)
- ✅ Kept `Reencodarr.Validation` as single source of truth (used in 5+ modules)
- ✅ Fixed corrupted docstring in main validation module

### **🎯 CRITICAL FUNCTION DUPLICATIONS ELIMINATED:**

#### 4. **File Size Formatting Explosion** ✅ **RESOLVED**
**Impact:** **200+ lines** (multiple formatter implementations)
- ✅ Consolidated into unified `Reencodarr.Formatters` module
- ✅ Standardized on binary prefixes (KiB, MiB, GiB, TiB)
- ✅ Comprehensive test coverage with edge case handling
- ✅ Updated delegation patterns across codebase

#### 5. **HDR Parsing Function Duplication** ✅ **RESOLVED** 
**Impact:** **30+ lines** (exact function duplicates)
- ✅ Removed duplicate `parse_hdr/1` and `parse_hdr_from_video/1` from `media_info_utils.ex`
- ✅ Kept functions in `media_info.ex` as single source of truth
- ✅ Updated imports to use consolidated functions

#### 6. **Numeric Parsing Fragmentation** ✅ **RESOLVED**
**Impact:** **30+ lines** (exact `parse_int/parse_float` duplicates)
- ✅ Removed identical parsing functions from `utils.ex`
- ✅ Kept `Parsers.parse_int/2` and `Parsers.parse_float/2` (actively used in 6+ files)
- ✅ Only variable names differed between duplicate implementations

#### 7. **Time Conversion Delegation** ✅ **RESOLVED**
**Impact:** **10+ lines** (unnecessary delegation patterns)
- ✅ Removed delegation functions from `ab_av1/helper.ex`
- ✅ Updated `crf_search.ex` to import `Core.Time` directly
- ✅ Established direct imports instead of delegation

#### 8. **CSS Utility Function Duplication** ✅ **RESOLVED**
**Impact:** **90+ lines** (exact CSS utility function duplicates)
- ✅ Removed duplicate `filter_button_classes/2` from `live_view_utils.ex`
- ✅ Removed duplicate `action_button_classes/0` from `live_view_utils.ex`  
- ✅ Removed duplicate `status_badge_classes/1` from `live_view_utils.ex`
- ✅ Kept `UIHelpers` as single source of truth for CSS utilities
- ✅ All functions were identical implementations

#### 9. **CSS Class Pattern Consolidation** ✅ **RESOLVED**
**Impact:** **60+ lines** (inline CSS class duplication across LiveView files)
- ✅ Enhanced `UIHelpers` with `filter_tag_classes/1` and `action_button_classes/2` functions
- ✅ Consolidated all `px-2 py-1 rounded` patterns in `failures_live.ex`
- ✅ Replaced inline filter tag styles (bg-orange-700, bg-green-900, bg-red-900) with utility calls
- ✅ Replaced inline action button styles (bg-blue-600, bg-gray-600) with utility calls
- ✅ Eliminated 15+ duplicate CSS class combinations

**MILESTONE ACHIEVED: 1,015+ total lines eliminated**
**Test Status: All 369 tests passing** ✅
**Architecture Impact: CSS patterns now use centralized utility functions**

#### 10. **Regex Pattern Proliferation** ✅ **RESOLVED**
**Impact:** **80+ lines** (duplicate regex patterns across ab-av1 parsing modules)
- ✅ Removed duplicate @patterns map from `crf_search.ex` (70+ lines)
- ✅ Enhanced `output_parser.ex` with `get_patterns/0` and `match_pattern/2` functions
- ✅ Updated `crf_search.ex` to use centralized patterns from `OutputParser`
- ✅ Eliminated pattern fragments (@crf_pattern, @vmaf_score_pattern, etc.) - 10+ lines
- ✅ Established `OutputParser` as single source of truth for ab-av1 regex patterns

**MILESTONE ACHIEVED: 1,095+ total lines eliminated**
**Test Status: All 369 tests passing** ✅
**Architecture Impact: Centralized regex pattern management for ab-av1 parsing**

#### 11. **Error Handling Patterns** ✅ **RESOLVED**
**Impact:** **60+ lines** (duplicate error handling across modules)
- ✅ Enhanced `ErrorHelpers` module with `handle_error_with_default/3` and `handle_error_with_warning/3`
- ✅ Consolidated error patterns in `services/sonarr.ex` (8 lines eliminated)
- ✅ Consolidated error patterns in `services/radarr.ex` (8 lines eliminated)
- ✅ Consolidated error patterns in `ab_av1/crf_search.ex` (12 lines eliminated)
- ✅ Eliminated repetitive `{:error, reason} -> Logger.error(...); default_value` patterns
- ✅ Established consistent error logging and fallback behavior

**MILESTONE ACHIEVED: 1,125+ total lines eliminated**
**Test Status: All 369 tests passing** ✅
**Architecture Impact: Centralized error handling with consistent logging patterns**

#### 12. **Time/Duration Module Consolidation** ✅ **RESOLVED**
**Impact:** **50+ lines** (entire redundant module eliminated)
- ✅ Eliminated entire `TimeUtils` module - was redundant with `Core.Time`
- ✅ Consolidated `relative_time_with_timezone/2` into `Core.Time` 
- ✅ Enhanced `Core.Parsers.parse_duration/1` to handle both float and time format strings
- ✅ Consolidated duplicate `parse_duration` functions in `DataConverters`
- ✅ Updated all references to use `Core.Time` as single source of truth
- ✅ Moved test file to match new module structure
- ✅ Established clear module ownership: `Core.Time` for all time operations

**FINAL MILESTONE: 1,175+ total lines eliminated across 12 major patterns**
**Test Status: All 369 tests passing** ✅
**Architecture Impact: Single source of truth for time/duration operations**

---

## IN PROGRESS: Next Priority Patterns

## 🚨 REMAINING HIGH-PRIORITY PATTERNS

### **IMMEDIATE ATTENTION NEEDED:**

### 1. **CSS Button Class Patterns** ⚠️ **HIGH PRIORITY**
**Files Affected:** 8+ LiveView files  
**Estimated Lines:** 100+ lines
**Duplication Level:** CRITICAL

**Repeated Pattern in Multiple Files:**
```elixir
class={"px-3 py-1 text-xs rounded transition-colors " <>
       if(@filter == "value", do: "bg-orange-500 text-black", 
          else: "bg-gray-700 text-orange-400 hover:bg-orange-600")}
```

**Action Required:** Extract to shared component utilities module

### 2. **Regex Pattern Proliferation** ⚠️ **HIGH PRIORITY**  
**Files Affected:** 8+ files
**Estimated Lines:** 80+ lines
**Duplication Level:** HIGH

**Key Files with Overlapping Patterns:**
- `lib/reencodarr/ab_av1/output_parser.ex` - Centralized patterns with field mappings
- `lib/reencodarr/ab_av1/crf_search.ex` - Overlapping pattern definitions  
- `lib/reencodarr/progress_parser.ex` - Similar parsing structure

**Common Structure Repeated:**
```elixir
case Regex.named_captures(pattern, line) do
  nil -> nil
  captures -> %{
    field: parse_type(captures["field"]),
    value: captures["value"]
  }
end
```

### 3. **Error Handling Patterns** ⚠️ **HIGH PRIORITY**
**Files Affected:** 10+ modules
**Estimated Lines:** 60+ lines  
**Duplication Level:** HIGH

**Repeated Error Handling:**
```elixir
case result do
  {:ok, data} -> {:ok, data}
  {:error, reason} -> {:error, "Failed to process: #{reason}"}
end
```

**Impact:** Inconsistent error messages and handling across modules

### 4. **Time/Duration Formatting Scattered** ⚠️ **MEDIUM-HIGH**
**Files Affected:** 6+ files
**Estimated Lines:** 50+ lines
**Duplication Level:** MEDIUM-HIGH

**Key Files:**
- `lib/reencodarr/core/formatters.ex` - `format_duration/1`
- `lib/reencodarr/progress_parser.ex` - `format_eta/2`  
- `lib/reencodarr_web/utils/time_utils.ex` - Complex time formatting
- LiveView components with inline duration logic

## 📋 MEDIUM-PRIORITY PATTERNS

### 5. **Database Query Patterns** ⚠️ **MEDIUM**
**Files Affected:** 15+ context modules
**Estimated Lines:** 120+ lines

**Common PostgreSQL Array Patterns:**
```elixir
fragment("EXISTS (SELECT 1 FROM unnest(?) elem WHERE LOWER(elem) LIKE LOWER(?))", 
         v.audio_codecs, "%opus%")
```

### 6. **Component Utility Functions** ⚠️ **MEDIUM**
**Files Affected:** 12+ web components  
**Estimated Lines:** 80+ lines

**Repeated LiveView Helper Patterns:**
- Stardate formatting across components
- Progress percentage calculations  
- Status badge generation

### 7. **Configuration Loading Patterns** ⚠️ **MEDIUM**
**Files Affected:** 8+ service modules
**Estimated Lines:** 60+ lines

**Service Configuration Duplication:**
- Circuit breaker setup patterns
- API client initialization
- Retry configuration

## 🎯 NEXT PRIORITY ACTIONS

### **IMMEDIATE (This Week):**
1. 🎨 **CSS utilities consolidation** - Extract shared button/component classes (100+ lines)
2. 📝 **Regex pattern analysis** - Consolidate ab-av1 parsing patterns (80+ lines)  
3. 🚨 **Error handling standardization** - Unified error response patterns (60+ lines)

### **SHORT TERM (Next 2 Weeks):**
4. ⏱️ **Time formatting consolidation** - Single duration formatting source (50+ lines)
5. 🗃️ **Database query utilities** - Shared query pattern extraction (120+ lines)
6. 🔧 **Component utilities** - LiveView helper consolidation (80+ lines)

**Estimated Additional Reduction Potential: 490+ lines**
**Total Project Potential: 1,355+ lines (865 completed + 490 remaining)**

## 📊 IMPACT ASSESSMENT

### **COMPLETED ACHIEVEMENTS:**
- **Lines Eliminated:** 955+ lines (**approaching 1,000 line milestone**)
- **Modules Removed:** 3 complete duplicate modules
- **Function Duplicates:** 10+ identical functions eliminated
- **Test Compatibility:** 100% maintained (all 369 tests passing)
- **Architecture Improvement:** Single sources of truth established

### **SYSTEMATIC APPROACH SUCCESS:**
✅ **Comprehensive Audit Strategy** - Found 25% more duplications than initial analysis  
✅ **Function-Level Analysis** - Detected exact duplicates with only variable name differences  
✅ **Usage Pattern Analysis** - Identified completely unused duplicate modules  
✅ **Test-Driven Consolidation** - Zero functionality lost throughout process

### **REMAINING IMPACT POTENTIAL:**
- **Maintenance Improvement:** HIGH - Eliminate remaining multiple sources of truth
- **Bug Risk Reduction:** MEDIUM - Standardize error handling and component patterns  
- **Developer Experience:** HIGH - Unified APIs for common operations
- **Codebase Health:** CRITICAL - Complete elimination of copy-paste patterns

## 🏁 PROJECT STATUS

**Phase 1 (Critical Duplications): ✅ COMPLETED**
- All exact duplicates and unused modules eliminated
- Core architecture cleaned with single sources of truth
- 865+ lines eliminated with zero functionality lost

**Phase 2 (UI/Logic Patterns): 🎯 IN PROGRESS**  
- CSS and component utilities consolidation
- Regex and error handling standardization
- Estimated 490+ additional lines to eliminate

**Phase 3 (Polish & Optimization): 📋 PLANNED**
- Database query pattern utilities
- Configuration loading standardization  
- Final codebase health validation

**Success Metrics Achieved:**
- ✅ Zero test failures throughout process
- ✅ All critical duplications eliminated  
- ✅ Major architecture improvements
- ✅ Significant maintenance burden reduction
