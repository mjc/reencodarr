defmodule Reencodarr.CrfSearchPolicyTest do
  use ExUnit.Case, async: true

  alias Reencodarr.CrfSearchPolicy
  alias Reencodarr.CrfSearchPolicy.Attempt

  @min_target 85

  test "a failed hinted range retries the same target over the full range" do
    attempt = %Attempt{target_vmaf: 95, crf_range: {20, 35}}

    assert {:retry, %Attempt{target_vmaf: 95, crf_range: {5, 70}}, :widen_range} =
             CrfSearchPolicy.retry(attempt, :process_failure, 0, @min_target)
  end

  test "a full-range optimization failure lowers the target by one" do
    attempt = %Attempt{target_vmaf: 95, crf_range: {5, 70}}

    assert {:retry, %Attempt{target_vmaf: 94, crf_range: {5, 70}}, :lower_target} =
             CrfSearchPolicy.retry(attempt, :crf_optimization, 0, @min_target)
  end

  test "a full-range size failure lowers the target by two" do
    attempt = %Attempt{target_vmaf: 95, crf_range: {5, 70}}

    assert {:retry, %Attempt{target_vmaf: 93, crf_range: {5, 70}}, :reduce_size} =
             CrfSearchPolicy.retry(attempt, :size_limits, 0, @min_target)
  end

  test "retry stops at the existing attempt limit and target floor" do
    attempt = %Attempt{target_vmaf: 95, crf_range: {5, 70}}
    assert :stop = CrfSearchPolicy.retry(attempt, :crf_optimization, 3, @min_target)

    floor = %Attempt{target_vmaf: @min_target, crf_range: {5, 70}}
    assert :stop = CrfSearchPolicy.retry(floor, :crf_optimization, 0, @min_target)
  end

  test "reconstructs an attempt from the exact assigned arguments" do
    args = [
      "crf-search",
      "--min-vmaf",
      "93",
      "--min-crf",
      "17",
      "--max-crf",
      "42"
    ]

    assert {:ok, %Attempt{target_vmaf: 93, crf_range: {17, 42}}} =
             CrfSearchPolicy.from_args(args)
  end
end
