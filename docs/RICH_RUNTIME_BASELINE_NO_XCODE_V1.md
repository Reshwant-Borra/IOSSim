# Rich Runtime Baseline — No-Xcode V1

Baseline commit: `0a18e986f40fd877a1aab1e91e4c6a87217c7c81`

The no-Xcode productization work treats the existing iPhone location runtime as
feature-frozen. Host setup changes must preserve this chain:

`LocalDevVPN -> RPPairing -> RSD -> DVT/TestManager -> XCTest runner -> XCUILocation`

The canonical `./iossim test` baseline passed before implementation on
2026-09-14. Existing deterministic checks cover:

- rich versus DVT fallback transport selection;
- route interpolation/resampling and constant-speed timing;
- speed, course, heading, and 2 Hz rich sample behavior;
- pause, resume, Stop & Hold, and destination hold;
- clear-on-stop and delayed-write rejection;
- single-writer and connection-generation protection;
- retained-session rebuild and reconnect position restoration;
- Mac-produced runner bundle mapping persistence and validation;
- pairing semantic validation and invalid-record replacement protection;
- provisioning bundle/team/profile relationships; and
- diagnostics and support-output secret redaction.

The historical physical gate order remains:

`RSD_READY -> TESTMANAGER_CONTROL_READY -> TESTMANAGER_MAIN_READY -> DVT_READY -> RUNNER_LAUNCHED -> PID_AUTHORIZED -> XCTEST_HANDSHAKE_READY -> TEST_PLAN_STARTED -> FINISHED`

No runtime algorithm is changed by this baseline commit. Any later narrow phone
change is limited to setup-envelope ingress and must not alter retained service
sessions, movement scheduling, location metadata, or generation semantics.

Physical requalification status: `AWAITING_PHYSICAL_VALIDATION`.
