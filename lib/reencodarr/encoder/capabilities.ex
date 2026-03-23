defmodule Reencodarr.Encoder.Capabilities do
  @moduledoc """
  Probes ffmpeg once to detect whether the svt-av1-hdr fork is in use.

  Caches the result in `:persistent_term` so the probe runs at most once per
  VM lifetime. In tests, set `encoder_capabilities_override: true | false` in
  the application env to bypass the probe entirely.
  """

  require Logger

  @spec svt_av1_hdr?() :: boolean()
  def svt_av1_hdr? do
    case Application.get_env(:reencodarr, :encoder_capabilities_override) do
      nil ->
        case :persistent_term.get(__MODULE__, :unprobed) do
          :unprobed ->
            result = probe()
            :persistent_term.put(__MODULE__, result)
            Logger.info("Encoder.Capabilities: svt-av1-hdr=#{result}")
            result

          cached ->
            cached
        end

      override ->
        override
    end
  end

  defp probe do
    args = ~w[
      -f lavfi -i nullsrc=s=16x16:r=1 -t 0.04
      -c:v libsvtav1 -svtav1-params tune=5 -f null -
    ]

    match?({_, 0}, System.cmd("ffmpeg", args, stderr_to_stdout: true))
  end
end
