defmodule Reencodarr.AbAv1.Helper do
  @moduledoc """
  Helper functions for ab-av1 operations.

  This module provides utility functions for working with ab-av1 parameters,
  VMAF data processing, and command-line argument manipulation.
  """

  require Logger

  alias Reencodarr.{Media, Rules}

  @spec attach_params(list(map()), Media.Video.t()) :: list(map())
  def attach_params(vmafs, video) do
    Enum.map(vmafs, &Map.put(&1, "video_id", video.id))
  end

  @spec remove_args(list(String.t()), list(String.t())) :: list(String.t())
  def remove_args(args, keys) do
    Enum.reduce(args, {[], false}, fn
      _arg, {acc, true} -> {acc, false}
      arg, {acc, false} -> if Enum.member?(keys, arg), do: {acc, true}, else: {[arg | acc], false}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec build_rules(Media.Video.t()) :: list()
  def build_rules(video) do
    Rules.apply(video)
    |> Enum.reject(fn {k, _v} -> k == "--acodec" end)
    |> Enum.flat_map(fn {k, v} -> [to_string(k), to_string(v)] end)
  end

  @spec convert_time_to_duration(map()) :: map()
  def convert_time_to_duration(captures) do
    Reencodarr.TimeHelpers.convert_time_to_duration(captures)
  end

  @spec convert_to_seconds(integer(), String.t()) :: integer()
  def convert_to_seconds(time, unit) do
    Reencodarr.TimeHelpers.to_seconds(time, unit)
  end

  @spec temp_dir() :: String.t()
  def temp_dir do
    temp_dir = Application.get_env(:reencodarr, :temp_dir)
    if File.exists?(temp_dir), do: temp_dir, else: File.mkdir_p(temp_dir)
  end

  @spec open_port([binary()]) :: port() | :error
  def open_port(args) do
    case System.find_executable("ab-av1") do
      nil ->
        Logger.error("ab-av1 executable not found")
        :error

      path ->
        Port.open({:spawn_executable, path}, [
          :binary,
          :exit_status,
          :line,
          :use_stdio,
          :stderr_to_stdout,
          args: args
        ])
    end
  end
end
