# macOS test status

The package contains 87 XCTest test methods covering 18 shared outcome fixtures, conservative diagnoses, HTTP 407, missing data, path and URL isolation, latency thresholds, pauses, anonymous report privacy, explicit report truncation, counter reset/sleep, settings, CSV, neighbour records, local recovery, strict AI JSON, unknown quota fields, and nettop counter differences.

These tests make no live service requests, run no Codex command, and consume no model quota. Store tests use a unique temporary directory and remove only that directory.

Status on 2026-10-29: source and fixtures were reviewed on Windows; shared JSON and embedded valid JSON fixtures were parsed locally. This host has no Swift compiler or macOS SDK. `swift test`, native linking, and the actual macOS UI/counter integration have NOT been run on this host. The GitHub macOS workflow is the next compilation and XCTest check. Do not report the 87 methods as passed until that workflow or an actual Mac run succeeds.

On Apple Silicon with Xcode Command Line Tools:

```sh
cd macos
swift test
```

A successful synthetic suite still requires a physical Mac smoke test: initial sampling, Wi-Fi/Ethernet switch, sleep/wake, VPN and explicit proxy/PAC, disabled targets, malformed local files, tray/floating-window behavior, notifications, and safe app shutdown.

