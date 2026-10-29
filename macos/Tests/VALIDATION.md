# macOS validation status

Commit f4155a8 was built on GitHub's macos-15-arm64 runner in run 40899571744 on 2026-10-29. The debug and release builds succeeded, and all 87 XCTest methods then present passed with zero failures. The app packaging step also completed. Both platform jobs failed only when uploading artifacts because the account's Actions artifact storage quota was full.

The current source contains 93 XCTest methods: 91 offline tests and two opt-in local macOS sampler checks. The four new CSV tests and the two sampler checks were added after that first successful build and still require the next CI run. Offline tests make no live service requests, run no Codex command, and consume no model quota. Temporary-file tests remove only their uniquely created directories.

The optional sampler tests require NETSCOPE_LOCAL_SMOKE=1. They read local 64-bit interface counters and bounded nettop output, do not issue service probes, do not invoke a model, and do not request sudo. A hosted runner check is not a replacement for Wi-Fi/Ethernet/VPN and sleep/wake testing on a physical Mac.

Run on a Mac with Xcode Command Line Tools:

    cd macos
    swift test
    NETSCOPE_LOCAL_SMOKE=1 swift test --filter MacIntegrationTests

Physical-device checks still needed: Wi-Fi/Ethernet switches, sleep/wake, VPN and explicit proxy/PAC, disabled targets, malformed local files, tray/floating-window behavior, notifications, and safe app shutdown. Never interpret unknown counters, denied nettop access, or missing proxy metrics as measured zero or proof of an outage.
