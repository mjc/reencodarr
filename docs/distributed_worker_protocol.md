# Distributed CRF-search Websocket Protocol

This document describes the current Reencodarr websocket contract for distributed
`ab-av1` CRF-search workers.

## Versioning

- Protocol version: `1`
- Transport: Phoenix websocket channel `workers:crf_search`
- Worker authentication: token-based socket connect, then per-worker channel join

## Connection Flow

1. Client connects to the websocket with the shared worker token.
2. Client joins `workers:crf_search`.
3. Client sends `announce`.
4. Server registers the worker session and returns `accepted: true`.
5. Client requests work with `pull_work` or `request_work`.
6. Server assigns work or returns `no_work`.

## Announce

Client payload:

- `worker_id`
- `protocol_version`
- `version`
- `capabilities`

Server accepts protocol version `1` and rejects unsupported versions.

## Job Assignment

Server reply:

- `status: "job_assigned"`
- `job_id`
- `video_id`
- `source_name`
- `size_bytes`
- `chunk_size_bytes`
- `target_vmaf`

The current chunk size is `1_048_576` bytes.

## Media Transfer

After assignment, the server streams the source file on the same websocket.

### `transfer_started`

Fields:

- `status: "transfer_started"`
- `video_id`
- `transfer_id`
- `source_name`
- `size_bytes`
- `chunk_size_bytes`
- `total_bytes`
- `total_chunks`

### `transfer_chunk`

Fields:

- `status: "transfer_chunk"`
- `video_id`
- `transfer_id`
- `chunk_index`
- `total_chunks`
- `bytes_sent`
- `total_bytes`
- `crc32`
- `data`

Notes:

- `chunk_index` starts at `0` and increments monotonically.
- `crc32` is computed from the raw chunk bytes.
- `data` is base64-encoded chunk data.

### `transfer_complete`

Fields:

- `status: "transfer_complete"`
- `video_id`
- `transfer_id`
- `total_bytes`
- `total_chunks`

### `transfer_failed`

Fields:

- `status: "transfer_failed"`
- `video_id`
- `transfer_id`
- `reason`

Transfer failures are recorded as file-access failures on the server side.

## Worker Events

The channel also accepts these client-to-server events:

- `heartbeat`
- `transfer_progress`
- `crf_search_progress`
- `crf_search_result`
- `crf_search_completed`
- `video_failed`

## Terminal State Rules

- `crf_search_completed` with `ok` marks the video searched and clears the active assignment.
- `crf_search_completed` with `cancelled` or `shutdown` returns the video to `analyzed`.
- `video_failed` records a structured failure and clears the active assignment.
- Disconnecting a worker with active CRF-search work requeues the video.

