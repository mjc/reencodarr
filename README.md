# Reencodarr

This is a WIP frontend for using the Rust CLI tool `ab-av1` to do bulk conversions based on time or space efficiency. It requires PostgreSQL for now but will not need it in the future.

It currently doesn't actually encode but that's next on the todo list.

To start your Reencodarr server for development:

  * make sure you have postgres set up and running locally with unix auth.
  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Planned Items

  - [x] Encoding
  - [ ] Docker image
  - [ ] Clustering
  - [ ] Remove PostgreSQL dependency
  - [ ] Flexible format selection rules (including toggling different kinds of hwaccel. cuda decoding is always on currently)
  - [ ] Automatic syncing
  - [x] Syncing button for Sonarr
  - [ ] Setup wizard
  - [ ] Radarr integration
  - [ ] Manual syncing
  - [ ] Authentication. Don't run this thing on the public internet. You've been warned.

## Learn more

  * `ab-av1` GitHub: https://github.com/alexheretic/ab-av1
  * `ab-av1` crates.io: https://crates.io/crates/ab-av1
  * FFmpeg: https://ffmpeg.org/
  * SVT-AV1: https://gitlab.com/AOMediaCodec/SVT-AV1
  * x265: https://bitbucket.org/multicoreware/x265_git/src/master/
  * VMAF: https://github.com/Netflix/vmaf
  * Why VMAF: https://netflixtechblog.com/toward-a-better-quality-metric-1b5bafa0b02d
