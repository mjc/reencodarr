defmodule Reencodarr.AbAv1.CrfSearchTest do
  @moduledoc """
  Unit tests for CRF search business logic functions.
  These tests focus on pure function behavior without GenServer interactions.
  """

  use ExUnit.Case, async: true
  alias Reencodarr.AbAv1.CrfSearch

  describe "has_preset_6_params?/1" do
    test "returns true when preset 6 params are present" do
      params_with_preset_6 = ["--preset", "6", "--other", "param"]
      assert CrfSearch.has_preset_6_params?(params_with_preset_6) == true
    end

    test "returns false when preset 6 params are not present" do
      params_without_preset_6 = ["--preset", "4", "--other", "param"]
      assert CrfSearch.has_preset_6_params?(params_without_preset_6) == false

      params_empty = []
      assert CrfSearch.has_preset_6_params?(params_empty) == false
    end
  end

  describe "build_crf_search_args_for_test/2" do
    test "builds basic CRF search args without preset 6" do
      video = %{path: "/test/video.mkv"}
      target_vmaf = 95

      args = CrfSearch.build_crf_search_args_for_test(video, target_vmaf)

      assert "crf-search" in args
      assert "--input" in args
      assert "/test/video.mkv" in args
      assert "--min-vmaf" in args
      assert "95" in args
      # Should NOT include preset 6 by default
      refute "--preset" in args || "6" in args
    end

    test "does not include preset 6 by default" do
      video = %{path: "/test/video.mkv"}
      target_vmaf = 90

      args = CrfSearch.build_crf_search_args_for_test(video, target_vmaf)

      # Should NOT include preset 6 by default
      refute "--preset" in args || "6" in args
    end

    test "always includes basic required arguments" do
      video = %{path: "/test/video.mkv"}
      target_vmaf = 90

      args = CrfSearch.build_crf_search_args_for_test(video, target_vmaf)

      assert "crf-search" in args
      assert "--input" in args
      assert "/test/video.mkv" in args
      assert "--min-vmaf" in args
      assert "90" in args
    end
  end

  describe "build_crf_search_args_with_preset_6_for_test/2" do
    test "includes preset 6 params" do
      video = %{path: "/test/video.mkv"}
      target_vmaf = 95

      args = CrfSearch.build_crf_search_args_with_preset_6_for_test(video, target_vmaf)

      assert "--preset" in args
      assert "6" in args
      assert "crf-search" in args
      assert "/test/video.mkv" in args
    end
  end
end
