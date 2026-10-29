# macOS validation status

Commit 36c037151b79312793f15831e23cb8ed37d31814 passed GitHub Actions run 40903372980 on the macos-15-arm64 runner on 2026-10-29. Both debug and release builds, the app packaging step, and the real local sampler checks succeeded. No Swift source warning was reported in this run.

The default XCTest stage listed 97 methods: 95 offline tests passed, while the two opt-in sampler methods were skipped as intended. The subsequent NETSCOPE_LOCAL_SMOKE=1 stage ran both sampler tests and passed both with zero failures or skips. All 97 distinct methods were therefore exercised successfully across these two stages.

Real runner evidence:
- 64-bit interface-counter check passed in 1.006 seconds.
- Production nettop capture check passed in 1.324 seconds.
- Nettop returned 20 process rows and a measured header-arrival window of 1.066312875 seconds. The application explicitly labels this as an approximate collection-window average, not an exact kernel instantaneous rate, and retains the actual observed byte differences.
- A normal pipe was experimentally found to buffer both samples until exit. The production capture now uses a fixed /usr/bin/script command with a private PTY to obtain line flushing; it opens no visible terminal, uses no shell and no sudo, and writes no transcript file.
- Unknown or indistinguishable sample timing preserves byte evidence and leaves rates unavailable instead of inventing zero or assuming the requested one-second delay.

Offline tests make no live service requests, run no Codex command, and consume no model quota. Temporary-file tests remove only their uniquely created directories. Optional sampler tests read local interface counters and bounded nettop output; they do not issue service probes or request elevation.

Run on a Mac with Xcode Command Line Tools:

    cd macos
    swift test
    NETSCOPE_LOCAL_SMOKE=1 swift test --filter MacIntegrationTests

The successful hosted-runner checks do not replace physical-device checks of Wi-Fi/Ethernet switches, sleep/wake, VPN and explicit proxy/PAC, tray/floating-window behavior, notifications, or day-long monitoring. Missing counters, denied nettop access, and unavailable proxy metrics remain unknown and are not proof of an outage.
