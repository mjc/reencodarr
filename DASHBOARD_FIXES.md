# Dashboard Fixes Summary

## Issues Fixed

### 1. Dashboard Shows "0 Total Videos" ✅ FIXED

**Problem:** The aggregated stats query was using `where: v.state != :failed`, but videos don't have a `:failed` state. They have a separate `failed: boolean` field.

**Files Fixed:**
- `/lib/reencodarr/media/shared_queries.ex` - Changed to `where: v.failed == false`

**Impact:** Total videos count now shows actual video count instead of 0.

### 2. CRF Search Debouncing Not Working ✅ FIXED  

**Problem:** Dashboard still lagging during CRF search progress updates despite debouncing.

**Files Fixed:**
- `/lib/reencodarr/ab_av1/crf_search.ex` - Made debouncing more aggressive:
  - Time threshold: 5 seconds → 10 seconds
  - Progress threshold: 5% → 10% progress change

**Impact:** Dashboard should update less frequently during CRF searches, reducing lag.

### 3. Bonus: Found Additional State vs Failed Boolean Issues ✅ FIXED

**Problem:** Other functions also incorrectly using `v.state == :failed` instead of `v.failed == true`.

**Files Fixed:**
- `/lib/reencodarr/media.ex` - `reset_all_failures/0` function
- `/lib/reencodarr/media/bulk_operations.ex` - `reset_all_failures/0` function

**Changes Made:**
- `where: v.state == :failed` → `where: v.failed == true`
- `set: [state: :needs_analysis]` → `set: [failed: false, state: :needs_analysis]`

## Test Results

- ✅ All 388 tests passing
- ✅ No compilation errors
- ✅ Media context tests pass
- ✅ CRF search tests pass

## Expected Results

1. **Dashboard Total Videos:** Should now show actual video count from database
2. **CRF Search Performance:** Dashboard should lag less during progress updates
3. **Failure Reset Functions:** Should now correctly find and reset failed videos

## Root Cause Analysis

The core issue was confusion between the video state machine states (`:needs_analysis`, `:analyzed`, `:crf_searched`, `:encoded`) and the separate `failed: boolean` field. The state machine never includes a `:failed` state - videos are marked as failed via the boolean field while retaining their processing state.

This was causing:
- Statistics queries to return 0 results (no videos matched `state != :failed`)
- Failure reset functions to not find any failed videos to reset
- Dashboard to show incorrect counts across the board
