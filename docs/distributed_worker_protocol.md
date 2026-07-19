# Distributed CRF-search Websocket Protocol

This document describes the current Reencodarr websocket contract for distributed
`ab-av1` CRF-search workers.

## Local supervised worker rollout

Reencodarr can replace its local CRF Broadway pipeline with one long-lived
worker-capable `ab-av1` process. Analysis and encoding remain on their existing
pipelines because worker protocol version 1 only advertises CRF-search work.

Set `REENCODARR_CRF_EXECUTION_MODE=worker`. Reencodarr then starts:

```text
ab-av1 worker --connect <REENCODARR_WORKER_CONNECT_URL> \
  --token <REENCODARR_WORKER_TOKEN> \
  --worker-id <REENCODARR_WORKER_ID> \
  --protocol-version 1
```

The process is supervised, logs are forwarded without printing the token, and
unexpected exits restart with bounded exponential backoff. The CRF Broadway
supervisor and local worker are mutually exclusive. Restore
`REENCODARR_CRF_EXECUTION_MODE=broadway` and restart to roll back; Broadway code
is intentionally retained during the rollout.

Before switching modes, drain active CRF work. After switching, use
`bin/rpc 'Reencodarr.Diagnostics.processes()'` to verify the process and websocket
session, then run a representative SDR and HDR job. Worker-owned
`:crf_searching` rows survive reconnects; only rows without a worker dispatch id
are reclaimed as orphaned local work.

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

The default chunk size is `134_217_728` bytes (128 MiB).

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

`transfer_chunk` is a binary Phoenix channel payload. It is not JSON and does
not base64-encode media bytes.

Frame layout:

- `magic`: 4 bytes, `RAV1`
- `version`: 1 byte, currently `1`
- `type`: 1 byte, currently `1` for transfer chunk
- `transfer_id_size`: 16-bit unsigned integer
- `video_id`: 64-bit unsigned integer
- `chunk_index`: 64-bit unsigned integer
- `total_chunks`: 64-bit unsigned integer
- `bytes_sent`: 64-bit unsigned integer
- `total_bytes`: 64-bit unsigned integer
- `crc32`: 32-bit unsigned integer
- `transfer_id`: `transfer_id_size` bytes
- `data`: raw chunk bytes

Notes:

- `chunk_index` starts at `0` and increments monotonically.
- `crc32` is computed from the raw chunk bytes.
- `data` is the raw file data for that chunk.

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
