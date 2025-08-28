defmodule Reencodarr.Client.BinaryValidator do
  @moduledoc """
  Validates that required binaries are available and have necessary capabilities.
  
  This module ensures that client nodes have the required external binaries
  (ab-av1, ffmpeg) with proper capabilities before starting processing services.
  """

  require Logger

  @doc """
  Validate all required binaries for client capabilities.
  
  Returns :ok if all required binaries are available and functional,
  {:error, reason} otherwise.
  """
  @spec validate_binaries() :: :ok | {:error, String.t()}
  def validate_binaries do
    capabilities = Reencodarr.Core.Mode.node_capabilities()
    
    with :ok <- validate_capability_binaries(capabilities) do
      Logger.info("All required binaries validated successfully")
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_capability_binaries(capabilities) do
    # CRF search and encoding both require ab-av1 and ffmpeg
    if Enum.any?(capabilities, &(&1 in [:crf_search, :encoding])) do
      with :ok <- validate_ab_av1(),
           :ok <- validate_ffmpeg() do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      # No processing capabilities requiring binaries
      :ok
    end
  end

  defp validate_ab_av1 do
    ab_av1_path = get_ab_av1_path()
    
    case System.cmd(ab_av1_path, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info("ab-av1 found: #{String.trim(output)}")
        :ok
        
      {_output, _code} ->
        {:error, "ab-av1 binary not found or not executable: #{ab_av1_path}"}
    end
  rescue
    _ -> 
      ab_av1_path = get_ab_av1_path()
      {:error, "Failed to execute ab-av1 binary at: #{ab_av1_path}"}
  end

  defp validate_ffmpeg do
    ffmpeg_path = get_ffmpeg_path()
    
    with :ok <- check_ffmpeg_executable(ffmpeg_path),
         :ok <- check_libvmaf_support(ffmpeg_path),
         :ok <- check_av1_support(ffmpeg_path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_ffmpeg_executable(ffmpeg_path) do
    case System.cmd(ffmpeg_path, ["-version"], stderr_to_stdout: true) do
      {output, 0} ->
        version_line = output |> String.split("\n") |> List.first()
        Logger.info("ffmpeg found: #{String.trim(version_line)}")
        :ok
        
      {_output, _code} ->
        {:error, "ffmpeg binary not found or not executable: #{ffmpeg_path}"}
    end
  rescue
    _ -> 
      ffmpeg_path = get_ffmpeg_path()
      {:error, "Failed to execute ffmpeg binary at: #{ffmpeg_path}"}
  end

  defp check_libvmaf_support(ffmpeg_path) do
    case System.cmd(ffmpeg_path, ["-hide_banner", "-filters"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "libvmaf") do
          Logger.info("ffmpeg has libvmaf support")
          :ok
        else
          {:error, "ffmpeg does not have libvmaf support - VMAF calculations will fail"}
        end
        
      {_output, _code} ->
        {:error, "Failed to check ffmpeg filters"}
    end
  end

  defp check_av1_support(ffmpeg_path) do
    case System.cmd(ffmpeg_path, ["-hide_banner", "-encoders"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "libsvtav1") do
          Logger.info("ffmpeg has AV1 encoding support")
          :ok
        else
          Logger.warning("ffmpeg may not have optimal AV1 encoding support")
          :ok  # Not critical since ab-av1 handles encoding
        end
        
      {_output, _code} ->
        {:error, "Failed to check ffmpeg encoders"}
    end
  end

  defp get_ab_av1_path do
    Application.get_env(:reencodarr, :ab_av1_path) || 
    detect_binary_path("ab-av1")
  end

  defp get_ffmpeg_path do
    Application.get_env(:reencodarr, :ffmpeg_path) || 
    detect_binary_path("ffmpeg")
  end

  defp detect_binary_path(binary_name) do
    case :os.type() do
      {:win32, _} -> "#{binary_name}.exe"
      {:unix, _} -> binary_name
    end
  end
end
