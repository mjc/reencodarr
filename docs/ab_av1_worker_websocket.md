# ab-av1 Worker Websocket

First REENC-133 server contract for CRF-search workers.

## Connection

- Websocket URL: `/workers/socket/websocket?token=<worker-token>`
- This is served by the main Phoenix app endpoint on the same host/port as the dashboard and API. It is not a separate service port.
- Runtime token env: `REENCODARR_WORKER_TOKEN`
- Phoenix channel topic: `workers:crf_search`

## Events

After joining `workers:crf_search`, send:

```json
{
  "event": "announce",
  "payload": {
    "worker_id": "abav1-dev",
    "version": "0.10.0",
    "capabilities": {"crf_search": true}
  }
}
```

Expected reply payload:

```json
{"accepted": true}
```

Then workers can ask for work:

```json
{"event": "pull_work", "payload": {}}
```

Current first-pass reply when no distributed job is available:

```json
{"status": "no_work"}
```

Current assigned-work reply:

```json
{
  "status": "job_assigned",
  "job_id": "123",
  "video_id": 123,
  "source_name": "movie.mkv",
  "size_bytes": 987654,
  "chunk_size_bytes": 1048576,
  "target_vmaf": 96.5
}
```

Workers only run one CRF search or encode at a time.

File transfer, chunk checksums, progress, result reporting, and requeue/failure handling are still pending REENC-133 follow-up slices.
