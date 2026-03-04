#!/usr/bin/env bash
# Demonstrates the different ways images attach to MP4/MKV files
# and why MP4Box -rem fails for certain cases.
#
# Test fixtures in test/support/fixtures/mp4_samples/:
#
# MP4 — covr metadata (iTunes-style):
#   covr_poster.mp4       — 1 MJPEG in covr atom (attached_pic=1). NOT a real track.
#   covr_two_posters.mp4  — 2 MJPEGs in covr atom. NOT real tracks.
#
# MP4 — real video tracks (trak box):
#   real_track_poster.mp4 — 1 MJPEG as real track. MP4Box CAN -rem this.
#   two_real_tracks.mp4   — 2 MJPEGs as real tracks. Sequential removal bug.
#   png_track.mp4         — 1 PNG as real track. Detected via codec_name.
#   mixed_mjpeg_png.mp4   — MJPEG + PNG as real tracks.
#   poster.m4v            — M4V extension with real MJPEG track.
#
# Clean baselines:
#   clean.mp4             — No attachments.
#   clean.mkv             — No attachments.
#
# MKV — mkvmerge attachments:
#   one_poster.mkv        — 1 JPEG attachment (mkvpropedit path).
#   two_posters.mkv       — JPEG + PNG attachments.

set -uo pipefail
FIXTURES="test/support/fixtures/mp4_samples"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

streams() {
  ffprobe -v quiet -print_format json -show_streams "$1" \
    | jq -c '[.streams[] | {i: .index, codec: .codec_name, ap: .disposition.attached_pic}]'
}

mp4box_tracks() {
  MP4Box -info "$1" 2>&1 | grep "Movie Info" | grep -oP '\d+ track'
}

# ──────────────────────────────────────────────────────────────
bold "═══ DEMO: MP4 Image Attachment Methods & Removal Bugs ═══"
echo

# ── Case 1: covr metadata (iTunes-style) ──
bold "CASE 1: covr metadata poster (covr_poster.mp4)"
echo "  ffprobe sees:  $(streams $FIXTURES/covr_poster.mp4)"
echo "  MP4Box sees:   $(mp4box_tracks $FIXTURES/covr_poster.mp4)"
echo "  → ffprobe shows mjpeg at index 1, but MP4Box only sees 1 track"
echo "  → The MJPEG is in the 'covr' metadata atom, NOT a trak box"
cp "$FIXTURES/covr_poster.mp4" "$TMP/covr_test.mp4"
if mp4box_out=$(MP4Box -rem 2 "$TMP/covr_test.mp4" 2>&1); then
  mp4box_exit=0
else
  mp4box_exit=$?
fi
if [[ $mp4box_exit -ne 0 ]]; then
  red "  → MP4Box -rem 2 FAILS (exit $mp4box_exit): 'Bad Parameter' — can't remove metadata!"
else
  green "  → MP4Box -rem 2 succeeded (unexpected)"
fi
echo "  → Must use ffmpeg remux fallback for covr metadata posters"
echo

# ── Case 2: Real video track ──
bold "CASE 2: Real MJPEG track (real_track_poster.mp4)"
echo "  ffprobe sees:  $(streams $FIXTURES/real_track_poster.mp4)"
echo "  MP4Box sees:   $(mp4box_tracks $FIXTURES/real_track_poster.mp4)"
cp "$FIXTURES/real_track_poster.mp4" "$TMP/real_test.mp4"
mp4box_out=$(MP4Box -rem 2 "$TMP/real_test.mp4" 2>&1)
mp4box_exit=$?
if [[ $mp4box_exit -eq 0 ]]; then
  remaining=$(streams "$TMP/real_test.mp4")
  green "  → MP4Box -rem 2 SUCCEEDS: $remaining"
else
  red "  → MP4Box -rem 2 failed (exit $mp4box_exit)"
fi
echo

# ── Case 3: Sequential removal bug ──
bold "CASE 3: Two real MJPEG tracks — Sequential Removal Bug (two_real_tracks.mp4)"
echo "  ffprobe sees:  $(streams $FIXTURES/two_real_tracks.mp4)"
echo "  MP4Box sees:   $(mp4box_tracks $FIXTURES/two_real_tracks.mp4)"

echo
bold "  BUG DEMO: Removing tracks 2,3 in ascending order (old code):"
cp "$FIXTURES/two_real_tracks.mp4" "$TMP/asc_test.mp4"
echo "    Step 1: MP4Box -rem 2"
MP4Box -rem 2 "$TMP/asc_test.mp4" 2>&1 | grep -E "Removing|Error" | sed 's/^/    /'
echo "    After step 1: $(streams "$TMP/asc_test.mp4")"
echo "    Step 2: MP4Box -rem 3"
if mp4box_out=$(MP4Box -rem 3 "$TMP/asc_test.mp4" 2>&1); then
  mp4box_exit=0
else
  mp4box_exit=$?
fi
remaining=$(streams "$TMP/asc_test.mp4")
if [[ $mp4box_exit -ne 0 ]]; then
  red "    → FAILS (exit $mp4box_exit): Track 3 doesn't exist after renumber"
  echo "    Remaining: $remaining"
  red "    → MJPEG STILL PRESENT — this is the bug!"
else
  echo "    Remaining: $remaining"
  green "    → Ascending also worked (track IDs preserved in this container)"
  echo "    NOTE: Track IDs don't always shift — depends on MP4 container impl."
  echo "    But covr metadata posters are the REAL bug (Case 1)."
fi

echo
bold "  FIX: Removing tracks 3,2 in descending order (new code):"
cp "$FIXTURES/two_real_tracks.mp4" "$TMP/desc_test.mp4"
echo "    Step 1: MP4Box -rem 3 (highest first)"
MP4Box -rem 3 "$TMP/desc_test.mp4" 2>&1 | grep -E "Removing|Error" | sed 's/^/    /'
echo "    After step 1: $(streams "$TMP/desc_test.mp4")"
echo "    Step 2: MP4Box -rem 2 (still valid!)"
MP4Box -rem 2 "$TMP/desc_test.mp4" 2>&1 | grep -E "Removing|Error" | sed 's/^/    /'
remaining=$(streams "$TMP/desc_test.mp4")
green "    → All posters removed: $remaining"
echo

# ── Case 4: PNG track ──
bold "CASE 4: PNG track (png_track.mp4)"
echo "  ffprobe sees:  $(streams $FIXTURES/png_track.mp4)"
echo "  → Detected via codec_name=='png', not attached_pic disposition"
echo

# ── Case 5: Mixed MJPEG + PNG ──
bold "CASE 5: Mixed MJPEG + PNG tracks (mixed_mjpeg_png.mp4)"
echo "  ffprobe sees:  $(streams $FIXTURES/mixed_mjpeg_png.mp4)"
echo "  MP4Box sees:   $(mp4box_tracks $FIXTURES/mixed_mjpeg_png.mp4)"
echo

# ── Case 6: M4V extension ──
bold "CASE 6: M4V extension (poster.m4v)"
echo "  ffprobe sees:  $(streams $FIXTURES/poster.m4v)"
echo "  → Same as MP4 but dispatched via mp4?() extension check"
echo

# ── Case 7: MKV attachments ──
bold "CASE 7: MKV with attachments (one_poster.mkv)"
echo "  ffprobe sees:  $(streams $FIXTURES/one_poster.mkv)"
echo "  → Cleaned via mkvpropedit (MIME-based, no track shifting issue)"
echo

bold "CASE 8: MKV with two attachments (two_posters.mkv)"
echo "  ffprobe sees:  $(streams $FIXTURES/two_posters.mkv)"
echo "  → mkvpropedit deletes by MIME type, not track number — no bug"
echo

# ── Summary ──
bold "═══ SUMMARY ═══"
echo "MP4 image attachment methods:"
echo "  1. covr metadata atom — ffprobe shows stream, MP4Box can't remove"
echo "  2. Real video track   — MP4Box can remove, but track IDs shift"
echo "  3. Both can appear in same file"
echo
echo "Bugs found:"
echo "  1. Sequential MP4Box -rem in ascending order shifts IDs → misses tracks"
echo "  2. covr metadata posters not removable via MP4Box at all"
echo "  3. Both require ffmpeg remux fallback as safety net"
