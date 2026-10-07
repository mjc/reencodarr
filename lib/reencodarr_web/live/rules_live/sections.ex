defmodule ReencodarrWeb.RulesLive.Sections do
  @moduledoc "Concise reference for the rules applied by Reencodarr.Rules."

  @sections [
    %{
      id: "overview",
      title: "Workflow",
      description: "Analyze → CRF search → Encode",
      facts: [
        {"Analyze", "The server reads file metadata and checks eligibility."},
        {"CRF search", "Workers test video samples to choose a CRF at the target VMAF."},
        {"Encode", "Workers encode the full file using the selected CRF and return the output."},
        {"Settings",
         "Video settings are shared between CRF search and encoding. Audio rules apply during encoding."}
      ]
    },
    %{
      id: "video_rules",
      title: "Video",
      description: "Default output settings.",
      facts: [
        {"Encoder", "SVT-AV1"},
        {"Preset", "6"},
        {"Parallelism", "lp=5"},
        {"Pixel format", "yuv420p10le · 10-bit 4:2:0"},
        {"Stock encoder tune", "0 · visual quality"},
        {"HDR fork tune", "6 for content before 2009; 2 for newer content."}
      ]
    },
    %{
      id: "audio_rules",
      title: "Audio",
      description: "Track decisions use detailed MediaInfo metadata.",
      facts: [
        {"Copy", "Existing Opus, TrueHD Atmos, E-AC-3 Atmos, and DTS:X tracks."},
        {"Transcode", "Other supported tracks use Opus. Mixed files use per-track overrides."},
        {"Bitrate caps", "Mono 64 kb/s · stereo 128 kb/s · 5.1 256 kb/s · 7.1 384 kb/s."},
        {"Lossy sources",
         "Bitrate is scaled by source codec efficiency and capped by channel count."},
        {"Channel layouts", "Non-standard layouts are normalized for receiver compatibility."},
        {"Incomplete metadata",
         "The file fails classification instead of guessing audio settings."},
        {"Unsupported formats",
         "Immersive AC-4, IAMF, and ADM in BW64 are rejected for Matroska output."}
      ]
    },
    %{
      id: "hdr_support",
      title: "HDR",
      description: "Flags depend on the source HDR type and encoder capabilities.",
      facts: [
        {"Dolby Vision", "--enc dolbyvision=1"},
        {"HDR10 / HDR10+", "The HDR fork uses --svt variance-boost-curve=3 for PQ content."},
        {"HLG", "No PQ curve override."},
        {"SDR", "No HDR flags."}
      ]
    },
    %{
      id: "resolution_scaling",
      title: "Resolution",
      description: "Scaling is based on source height.",
      facts: [
        {"2160 pixels or higher", "Scale to 1920 pixels wide with --vfilter scale=1920:-2."},
        {"Below 2160 pixels", "Keep the source resolution."},
        {"Aspect ratio",
         "Height is calculated from the source aspect ratio and rounded to an even number."}
      ]
    },
    %{
      id: "helper_rules",
      title: "Film grain",
      description: "Grain synthesis applies to content released before 2009.",
      facts: [
        {"Release year", "Use the stored content year, then try the title and path."},
        {"HDR fork", "Strength 12; strength 20 when source bitrate is at least 20 Mb/s."},
        {"HDR fork options", "film-grain-denoise=1 and adaptive-film-grain=1."},
        {"Stock encoder", "Film grain strength 8."},
        {"Newer or unknown year", "No film grain override."}
      ]
    },
    %{
      id: "crf_search",
      title: "CRF search",
      description: "The original file size determines the initial VMAF target.",
      facts: [
        {"Up to 25 GiB", "VMAF 95"},
        {"Over 25 GiB", "VMAF 94"},
        {"Over 40 GiB", "VMAF 92"},
        {"Over 60 GiB", "VMAF 91"},
        {"Retry floor", "Up to 2 points below the initial target, with a minimum of 90."},
        {"Sample progress",
         "6/8 means six samples of the current CRF trial. It is not overall search completion."}
      ]
    },
    %{
      id: "command_examples",
      title: "Arguments",
      description:
        "Common video flags. Source-specific HDR, grain, scaling, and audio flags are added as needed.",
      facts: [
        {"--svt", "SVT-AV1 encoder parameters."},
        {"--enc", "FFmpeg output options and per-track audio overrides."},
        {"Precedence",
         "Explicit base flags override additional parameters, which override automatic rules."}
      ],
      example: "--encoder svt-av1 --preset 6 --svt lp=5 --pix-format yuv420p10le"
    }
  ]

  def all, do: @sections
  def find(id), do: Enum.find(@sections, hd(@sections), &(&1.id == id))
end
