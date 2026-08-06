# Worker mode parity gate

This is the cutover gate for [REENC-150](https://lific.mjc.lol/REENC/issues/REENC-150).
“Shared” means both execution modes call the same production module. “Worker” means
the WebSocket path owns transport/lifecycle behavior that has no Broadway equivalent.

| Behavior | Owner and disposition | Executable proof |
| --- | --- | --- |
| Analysis dispatch | Intentionally retained in `Analyzer.Broadway`; worker mode replaces only ab-av1 CRF/encode execution ([REENC-150](https://lific.mjc.lol/REENC/issues/REENC-150)) | `Analyzer.Broadway.ProducerTest`, `SyncIntegrationTest` |
| CRF and encode eligibility/claiming | Shared `Media.VideoQueries`; worker adds capability, weighted scheduling, and atomic disk-admission callback | `VideoQueriesTest`, `WorkerChannelTest`, `WorkerAdmissionTest` |
| Argument construction, preset, HDR, and audio | Shared `Rules`; all three entry points are contract-tested byte-for-byte | `RulesIntegrationTest`, `RulesTest`, `Encoder.AudioArgsTest` |
| CRF hints and retry policy | Shared `CrfSearchPolicy`; legacy and worker persist the exact target/range and use the same retry decision ([REENC-153](https://lific.mjc.lol/REENC/issues/REENC-153)) | `CrfSearchPolicyTest`, `CrfSearchVmafRetryTest`, `WorkerChannelTest` |
| Disk admission | Worker implementation because capacity belongs to the executing worker; local and remote source-copy costs differ ([REENC-154](https://lific.mjc.lol/REENC/issues/REENC-154)) | `WorkerAdmissionTest`, `WorkerChannelTest` |
| State transitions and attempt fencing | Shared `Media`/`VideoStateMachine`; worker transitions require the persisted `job_id` | `WorkerControlTest`, `WorkerChannelTest`, `WorkerSessionsTest`, `VideoStateMachineTest` |
| Exit/failure mapping and context | Shared ab-av1 exit mapping and `FailureTracker`; worker carries the binary-equivalent typed failure payload ([REENC-153](https://lific.mjc.lol/REENC/issues/REENC-153)) | `OutputParserTest`, `FailureTrackerTest`, `WorkerChannelTest` |
| Successful replacement and saved bytes | Shared `PostProcessor`; worker upload commit is attempt-fenced before post-processing | `PostProcessorTest`, `VideoProcessingPipelineTest`, `WorkerFileControllerTest`, `WorkerChannelTest` |
| Temporary-file cleanup and retention | Shared server `TempCleaner`; ab-av1 worker owns its per-attempt input/output directory and cleans after terminal acknowledgement | `TempCleanerTest`, ab-av1 `worker::tests` and `worker_transfer_tests` |
| Disconnect, reconnect, duplicate terminal delivery | Worker lifecycle implementation; exact attempts survive reconnect and terminal delivery is idempotent ([REENC-148](https://lific.mjc.lol/REENC/issues/REENC-148)) | `WorkerSessionsTest`, `WorkerChannelTest`, ab-av1 `worker_reconnect_tests` |
| Stalled-job recovery | Worker watchdog observes meaningful job activity, not heartbeat; default 23-hour warning and 24-hour exact-attempt Stop match legacy health-check policy ([REENC-151](https://lific.mjc.lol/REENC/issues/REENC-151)) | `WorkerSessionsTest`, `WorkerControlTest` |
| Pause, resume, stop, and scheduled 2am resume | Shared persisted control state and `ProcessControl`; worker commands are independently addressed and acknowledged | `WorkerControlTest`, `ProcessControlTest`, `WorkerChannelTest` |
| Dashboard events and controls | Shared `Dashboard.Events`; worker panels derive CRF and encode state independently per job | `DashboardV2StatusBroadcastTest`, `DashboardV2LiveTest`, `WorkerActivityTest` |
| Diagnostics | Worker session diagnostics add job phase, last meaningful activity, stall age, recovery, and admission decision | `WorkerSessionsTest`, `DiagnosticsTest` |

There are no unowned policy differences. `AbAv1.CrfSearch`, `AbAv1.Encode`, and
`Encoder.HealthCheck` remain rollback executors, but unique production decisions have
moved to shared policy modules or have the explicit worker implementations above.

## Production cutover proof

Before closing REENC-150, use `bin/rpc` against the deployed generation and record
exact attempt IDs for:

1. a retry whose next assignment reflects the persisted CRF attempt;
2. an encode admission refusal with available and required bytes;
3. watchdog phase/activity/recovery visibility;
4. an encode whose original is replaced and `space_saved_bytes` is persisted; and
5. cleanup of that attempt's server and worker temporary files.
