#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/mnt/tv}"
PATTERN="${2:-.}"

if ! command -v fd >/dev/null 2>&1; then
  echo "fd is required" >&2
  exit 1
fi

if ! command -v mediainfo >/dev/null 2>&1; then
  echo "mediainfo is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

fd \
  --type f \
  --extension mkv \
  --extension mp4 \
  --extension m4v \
  --extension mov \
  --extension ts \
  --extension m2ts \
  "$PATTERN" \
  "$ROOT" \
  -X bash -c '
    for file in "$@"; do
      base=$(basename "$file")
      case "$base" in
        *1080*|*1080p*) ;;
        *) continue ;;
      esac
      case "$base" in
        *DV*|*dv*) ;;
        *) continue ;;
      esac

      mediainfo --Output=JSON "$file" 2>/dev/null \
        | jq -er --arg file "$file" '"'"'
            [
              .media.track[]?
              | select(."@type" == "Video")
              | select(
                  (
                    ((.HDR_Format // "") | ascii_downcase | contains("dolby vision"))
                    or ((.HDR_Format_Profile // "") | ascii_downcase | startswith("dvhe."))
                    or ((.HDR_Format_Profile // "") | ascii_downcase | startswith("dvh1."))
                  )
                )
              | select((.MasteringDisplay_ColorPrimaries // "") == "")
              | select((.MasteringDisplay_Luminance // "") == "")
              | select((.MaxCLL // "") == "")
              | select((.MaxFALL // "") == "")
              | $file
            ]
            | .[]
            | .
          '"'"' || true
    done
  ' bash \
  | awk -F/ '
      {
        show = $(NF - 2)
        season = $(NF - 1)
        key = show "\t" season
        count[key]++
      }

      END {
        for (key in count) {
          split(key, parts, "\t")
          printf "%s\t%s\t%d\n", parts[1], parts[2], count[key]
        }
      }
    ' \
  | sort -t $'\t' -k1,1 -k2,2V \
  | awk -F'\t' '
      $1 != current {
        if (NR > 1) {
          print ""
        }
        current = $1
        print current
      }

      {
        printf "  %s (%s)\n", $2, $3
      }
    '
