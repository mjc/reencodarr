# Media fixtures

The E-AC-3 and DTS-HD MA fixtures are one-second stream-copy excerpts from the public
[FFmpeg E-AC-3](https://samples.ffmpeg.org/A-codecs/AC3/eac3/sample-eac3.mkv) and
[DTS-HD MA](https://samples.ffmpeg.org/A-codecs/DTS/dts/Master%20Audio%205.0%2096khz.dts)
samples. Matroska BPS and stream-size statistics tags were removed with `mkvpropedit` so tests
exercise MediaInfo's full-file scan.

`mediainfo_object_audio_production.json` and `mediainfo_encode_queue_production.json` contain
classification fields captured from production MediaInfo rows on 2026-08-10. They intentionally
omit paths and unrelated metadata.
