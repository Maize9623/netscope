# NetScope measurement contract

This document defines the meaning of measurements shared by the Windows and native macOS implementations. It is not a claim that both platforms expose identical OS counters. The macOS implementation is new and has not yet been built or verified on a physical Mac in this Windows development session.

## Observation, inference, and missing data

An observation describes this computer, the configured request, and one time interval. It does not establish the health of an entire provider, a company's network, or all devices on a LAN. `confidence` is qualitative (high/medium/low or corresponding Chinese text), never an invented percentage. Default UI titles and advice use ordinary language; protocol codes and measured numbers belong in expandable evidence.

A HTTP response means something on the request path replied. It does not establish login, content generation, paid API access, full page load, or throughput. A successful small request is not a speed test. A link's negotiated Mbps is not measured available bandwidth. A virtual interface being up is not proof of a healthy VPN node.

| Result | HTTP response denominator | Positive control | Transport failure | Meaning |
|---|---:|---:|---:|---|
| 2xx | yes | yes | no | Endpoint responded; inference was not tested |
| 3xx | yes | yes | no | Redirect received; final destination not checked |
| 401/403/404/405 | yes | yes | no | Response received; authentication/policy/path/method restrictions |
| 407 | yes | no | no | Proxy requires authentication; target not validated |
| 429 | yes | yes | no | A response on the path reports throttling; account/provider scope unknown |
| 5xx | yes | no | no | Server/proxy/CDN response error; origin and global scope unknown |
| timeout/DNS/TLS/proxy/connect failure | yes | no | yes | Attempted observation failed, as classified by collector |
| skipped/internal error/invalid URL | no | no | no | Missing or invalid observation; never insert zero or failure |

In the denominator column, `yes` for a transport failure means the attempted request is included when calculating the response proportion, not that a response occurred. `probe-cases.json` uses explicit `countsAsAttempt`, `httpResponse`, and `positiveControl` fields to avoid this ambiguity.

An ICMP timeout alone is no more than 'no reply'. Direct DNS/TCP checks and HTTP through a proxy may take different paths; direct failures with successful HTTP do not prove a service outage. 407 cannot support 'domestic controls were responding normally'. No response-level status, including 401, must be turned into packet loss.

## Identity, history, and continuity

Baselines are scoped to target ID + configured URL + network configuration fingerprint (`pathID`). The fingerprint indicates a configuration, not a proven physical route or actual VPN exit. A node can change without its configuration fingerprint changing. Historic URLs retain their identity even if the user later edits a target.

Use only real samples with real UTC timestamps. Deduplicate exact target/path/timestamp observations when the same result is present in more than one frame. A sleep, pause, cancellation, collector error, or skipped sample is not a disconnection. Such gaps break 'consecutive' evidence. A current latency warning requires at least five valid previous observations from the same identity in the last 30 minutes, a current response slower than three times their median, and a current response over 1500 ms. Do not use a 407 response as a target latency baseline.

Two adjacent real transport failures may justify a stronger local-path warning. They still do not identify a global outage. Comparing unrelated target groups is supporting evidence, not causation. Group labels such as domestic and international are user-facing control sets, not measured geolocation or proof of routing.

## Rates and statistical output

Counter differences divided by positive elapsed seconds produce byte-per-second rates. First sample, counter decrease/reset, adapter change, invalid elapsed time, and sleep-sized gaps produce unknown rates. Unknown is not zero. Do not add physical and virtual interface counters and call the sum WAN traffic. Per-process event observations and physical wire counters have different scopes; proxy/VPN duplication is possible.

A history summary states the actual observation range, number of frames, sample count per target/path, HTTP response percentage, attempted-sample transport failure percentage, timeout percentage, and P50/P95 response duration. Percentages describe sampled requests, never packet loss. Timing statistics include only finite nonnegative measured HTTP durations, exclude missing observations and proxy-authentication-only responses, and do not imply content-generation performance. Percentiles use linear interpolation between ordered observations.

CSV export quotes values and doubles embedded quotes. After trimming leading whitespace, text beginning with `=`, `+`, `-`, or `@` is prefixed with an apostrophe so opening it in a spreadsheet does not execute formulas. URL configuration allows only HTTP/HTTPS and rejects URL credentials. OS neighbour caches are a partial list of recently observed neighbours; their presence, names, and connection counts do not reveal their bandwidth usage or establish device ownership.

## Privacy of AI reports

Anonymous model input must omit raw IPs, MACs, URLs, hostnames, user-provided labels, interface names/IDs, process names, and raw path fingerprints. Assign local sequential aliases to each historic target+URL+path identity. Emit only measured numbers, known classifications, generic group labels, and explicit limitations. The application retains the exact submitted input locally with its resulting report so a later configuration change cannot rewrite past evidence. The user decides whether to request an unredacted local export; that export is not automatically sent to a model.

## Reproducible verification

The Swift package targets Swift 5.9 and macOS 14 with no third-party package dependencies. On an Apple Silicon Mac with Xcode Command Line Tools, run `cd macos && swift test`. Tests are synthetic/local and do not contact AI services, query a router, invoke Codex, or consume model quota. Passing tests does not replace a real Mac smoke test of counters, sleep/wake, proxy configurations, storage permissions, menu-bar UI, notifications, and application packaging.

