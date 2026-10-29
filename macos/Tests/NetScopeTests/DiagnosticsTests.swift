import Foundation
import XCTest
@testable import NetScope

final class DiagnosticsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func probe(_ seconds: Double = 0, id: String = "a", status: Int? = 200, outcome: ProbeOutcome = .ok, path: String = "home", group: String = "AI", ms: Double? = 100) -> ProbeResult {
        var p = ProbeResult(); p.at = base.addingTimeInterval(seconds); p.targetID = id; p.name = "应用" + id
        p.url = "https://example.test/" + id; p.statusCode = status; p.outcome = outcome
        p.reachable = status != nil; p.pathID = path; p.group = group; p.httpMs = ms
        return p
    }
    private func frame(_ probes: [ProbeResult], seconds: Double = 0) -> MonitorFrame {
        var f = MonitorFrame(); f.at = base.addingTimeInterval(seconds); f.local.at = f.at; f.probes = probes
        f.local.trafficRateReady = true; f.local.downloadBps = 0; f.local.uploadBps = 0
        return f
    }
    private func result(_ probes: [ProbeResult], history: [MonitorFrame] = []) -> [Finding] { Diagnostics.evaluate(frame: frame(probes), history: history) }
    private func has(_ rows: [Finding], _ prefix: String) -> Bool { rows.contains { $0.id.hasPrefix(prefix) } }
    private func history(_ count: Int, status: Int = 200, path: String = "home", ms: Double = 100) -> [MonitorFrame] {
        (1...count).map { n in frame([probe(-Double(n * 30), status: status, path: path, ms: ms)], seconds: -Double(n * 30)) }
    }

    func testSharedClassificationFixtures() throws {
        struct Cases: Decodable { var cases: [Case] }
        struct Case: Decodable { var name: String; var statusCode: Int?; var outcome: ProbeOutcome; var countsAsAttempt: Bool; var httpResponse: Bool; var positiveControl: Bool; var transportFailure: Bool }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/probe-cases.json"))
        let cases = try JSONDecoder().decode(Cases.self, from: data).cases
        XCTAssertEqual(cases.count, ProbeOutcome.allCases.count)
        for item in cases {
            let p = probe(status: item.statusCode, outcome: item.outcome)
            XCTAssertEqual(!Diagnostics.isMissing(p), item.countsAsAttempt, item.name)
            XCTAssertEqual(Diagnostics.httpStatus(p) != nil, item.httpResponse, item.name)
            XCTAssertEqual(Diagnostics.isPositiveControl(p), item.positiveControl, item.name)
            XCTAssertEqual(Diagnostics.isTransportFailure(p), item.transportFailure, item.name)
            XCTAssertEqual(p.outcome.isHTTPResponse, item.httpResponse, item.name)
            XCTAssertEqual(p.outcome.isPositiveControl, item.positiveControl, item.name)
        }
    }
    func testAuthenticationAndAccessRestrictionsAreNotTransportFailures() {
        for code in [401, 403, 404, 405] {
            let rows = result([probe(status: code, outcome: .httpError)])
            XCTAssertFalse(has(rows, "connect:")); XCTAssertTrue(has(rows, "access-response:"))
            XCTAssertTrue(rows.allSatisfy { $0.severity == .info })
        }
    }
    func testHTTPStatusTakesPrecedenceOverIndependentCollectorErrors() {
        let p = probe(status: 200, outcome: .dnsError)
        XCTAssertFalse(Diagnostics.isTransportFailure(p)); XCTAssertFalse(Diagnostics.isMissing(p))
        XCTAssertTrue(Diagnostics.isPositiveControl(p)); XCTAssertFalse(has(result([p]), "connect:"))
    }
    func testRateLimitDoesNotClaimGlobalOutageOrAccountExhaustion() {
        let rows = result([probe(status: 429, outcome: .rateLimited)])
        XCTAssertTrue(has(rows, "rate-limit:")); XCTAssertFalse(has(rows, "connect:"))
        XCTAssertTrue(rows.contains { $0.evidence.contains("不能据此推算账号剩余额度") })
    }
    func testServerErrorsRetainProxyAndCDNAlternative() {
        let rows = result([probe(status: 503, outcome: .serverError)])
        XCTAssertTrue(has(rows, "server-response:")); XCTAssertFalse(has(rows, "connect:"))
        XCTAssertTrue(rows.contains { $0.evidence.contains("代理或 CDN") })
        XCTAssertFalse(Diagnostics.isPositiveControl(probe(status: 503, outcome: .serverError)))
    }
    func testRedirectDoesNotValidateFinalDestination() {
        XCTAssertTrue(result([probe(status: 302, outcome: .redirect)]).contains { $0.evidence.contains("未继续访问") })
    }
    func testProxyAuthenticationIsResponseButNotTargetControl() {
        let p = probe(status: 407, outcome: .proxyAuthRequired)
        let rows = result([p]); XCTAssertTrue(has(rows, "proxy-auth:")); XCTAssertFalse(has(rows, "connect:"))
        XCTAssertNotNil(Diagnostics.httpStatus(p)); XCTAssertFalse(Diagnostics.isPositiveControl(p))
        let report = Diagnostics.buildReport(frames: [frame([p])], anonymized: true)
        XCTAssertTrue(report.contains("收到回应 1/1")); XCTAssertTrue(report.contains("未验证目标")); XCTAssertTrue(report.contains("P50 未知"))
    }
    func testOnlyProxyAuthenticationCannotEstablishDomesticNormal() {
        let rows = result([probe(id: "d", status: 407, outcome: .proxyAuthRequired, group: "国内"), probe(id: "a", status: nil, outcome: .timeout), probe(id: "b", status: nil, outcome: .connectError)])
        XCTAssertFalse(has(rows, "correlation:selective-connectivity")); XCTAssertFalse(has(rows, "correlation:isolated"))
    }
    func testOnlyServerErrorCannotEstablishDomesticNormal() {
        let rows = result([probe(id: "d", status: 502, outcome: .serverError, group: "国内"), probe(id: "a", status: nil, outcome: .timeout), probe(id: "b", status: nil, outcome: .timeout)])
        XCTAssertFalse(has(rows, "correlation:selective-connectivity"))
    }
    func testMissingObservationsHaveNoTransportFailure() {
        for outcome in [ProbeOutcome.skipped, .error, .invalidURL] {
            let p = probe(status: nil, outcome: outcome)
            XCTAssertTrue(Diagnostics.isMissing(p)); XCTAssertFalse(Diagnostics.isTransportFailure(p))
            XCTAssertTrue(has(result([p]), "probes:missing")); XCTAssertFalse(has(result([p]), "connect:"))
        }
    }
    func testInconsistentSuccessfulOutcomeWithNoStatusRemainsUnknown() {
        XCTAssertTrue(Diagnostics.isMissing(probe(status: nil, outcome: .ok)))
        XCTAssertFalse(Diagnostics.isPositiveControl(probe(status: nil, outcome: .ok)))
    }
    func testSingleFailureIsInformational() {
        XCTAssertEqual(result([probe(status: nil, outcome: .timeout)]).first { $0.id.hasPrefix("connect:") }?.severity, .info)
    }
    func testTwoAdjacentFailuresGetWarning() {
        let rows = result([probe(status: nil, outcome: .timeout)], history: [frame([probe(-30, status: nil, outcome: .timeout)], seconds: -30)])
        XCTAssertEqual(rows.first { $0.id.hasPrefix("connect:") }?.severity, .warning)
    }
    func testSleepGapDoesNotCountConsecutiveFailure() {
        let rows = result([probe(status: nil, outcome: .timeout)], history: [frame([probe(-3600, status: nil, outcome: .timeout)], seconds: -3600)])
        XCTAssertEqual(rows.first { $0.id.hasPrefix("connect:") }?.severity, .info)
    }
    func testSkippedAndUnknownBreakConsecutiveEvidence() {
        for outcome in [ProbeOutcome.skipped, .error] {
            let past = [frame([probe(-60, status: nil, outcome: .timeout)], seconds: -60), frame([probe(-30, status: nil, outcome: outcome)], seconds: -30)]
            XCTAssertEqual(result([probe(status: nil, outcome: .timeout)], history: past).first { $0.id.hasPrefix("connect:") }?.severity, .info)
        }
    }
    func testPathChangeAndReturnBreaksConsecutiveEvidence() {
        let past = [frame([probe(-60, status: nil, outcome: .timeout, path: "home")], seconds: -60), frame([probe(-30, status: nil, outcome: .timeout, path: "office")], seconds: -30)]
        XCTAssertEqual(result([probe(status: nil, outcome: .timeout, path: "home")], history: past).first { $0.id.hasPrefix("connect:") }?.severity, .info)
    }
    func testMultiTargetComparisonIsConditionalAndNotGlobalConclusion() {
        let rows = result([probe(id: "d", group: "国内"), probe(id: "a", status: nil, outcome: .timeout), probe(id: "b", status: nil, outcome: .timeout)])
        let finding = rows.first { $0.id == "correlation:selective-connectivity" }
        XCTAssertNotNil(finding); XCTAssertEqual(finding?.severity, .info)
        XCTAssertTrue(finding?.advice.contains("目前不能定责") == true)
        XCTAssertTrue(finding?.evidence.contains("2/2") == true)
    }
    func testSingleTargetFailureRetainsMultiplePossibleCauses() {
        let rows = result([probe(id: "d", group: "国内"), probe(id: "a", status: nil, outcome: .timeout)])
        XCTAssertTrue(has(rows, "correlation:isolated")); XCTAssertTrue(rows.contains { $0.advice.contains("访问路径、限制或服务本身") })
    }
    func testMissingGatewayDoesNotProduceFailure() {
        var f = frame([probe()]); f.gatewayMs = nil; f.local.gateway = nil
        XCTAssertFalse(Diagnostics.evaluate(frame: f, history: []).contains { $0.severity != .info })
    }
    func testKnownInterfacesDownSupportsLocalFinding() {
        var f = frame([probe(status: nil, outcome: .timeout)]), adapter = AdapterInfo()
        adapter.id = "en0"; adapter.isUp = false; f.local.adapters = [adapter]
        XCTAssertEqual(Diagnostics.evaluate(frame: f, history: []).first { $0.id == "local:no-active-interface" }?.severity, .critical)
    }
    func testMissingAdapterInventoryDoesNotProveLocalDisconnect() {
        XCTAssertFalse(has(result([probe()]), "local:no-active-interface"))
    }
    func testVirtualInterfaceUpDoesNotProveHealthyNode() {
        var f = frame([probe()]), adapter = AdapterInfo(); adapter.id = "utun9"; adapter.isUp = true; adapter.isVirtual = true; f.local.adapters = [adapter]
        let finding = Diagnostics.evaluate(frame: f, history: []).first { $0.id == "local:virtual-interface" }
        XCTAssertTrue(finding?.evidence.contains("不代表 VPN 节点健康") == true)
    }
    func testLatencyNeedsAtLeastFiveSamples() {
        XCTAssertFalse(has(result([probe(ms: 2000)], history: history(4)), "slow:"))
        XCTAssertTrue(has(result([probe(ms: 2000)], history: history(5)), "slow:"))
    }
    func testLatencyThresholdRequiresBothStrictLimits() {
        XCTAssertFalse(has(result([probe(ms: 1500)], history: history(5)), "slow:"))
        XCTAssertFalse(has(result([probe(ms: 1800)], history: history(5, ms: 600)), "slow:"))
        XCTAssertTrue(has(result([probe(ms: 1801)], history: history(5, ms: 600)), "slow:"))
    }
    func testLatencyBaselineIsolatedByConfiguration() {
        XCTAssertFalse(has(result([probe(ms: 2000)], history: history(5, path: "office")), "slow:"))
    }
    func testLatencyBaselineExcludesProxyAuthentication() {
        XCTAssertFalse(has(result([probe(ms: 2000)], history: history(5, status: 407)), "slow:"))
    }
    func testLatencyBaselineExcludesOldSamples() {
        let past = (1...5).map { n in frame([probe(-Double(2000 + n * 30))], seconds: -Double(2000 + n * 30)) }
        XCTAssertFalse(has(result([probe(ms: 2000)], history: past), "slow:"))
    }
    func testSummaryDeduplicatesProbesAndLocalRates() {
        let f = frame([probe()]), report = Diagnostics.buildReport(frames: [f, f], anonymized: true)
        XCTAssertTrue(report.contains("去重服务样本 1 次")); XCTAssertTrue(report.contains("有效下载采样 1 次"))
    }
    func testSummaryDenominatorExcludesMissingAndRetainsUnauthorizedResponse() {
        let samples = [probe(-90, status: 401, outcome: .authRequired), probe(-60, status: nil, outcome: .timeout), probe(-30, status: nil, outcome: .skipped), probe(status: nil, outcome: .error)]
        let report = Diagnostics.buildReport(frames: [frame(samples)], anonymized: true)
        XCTAssertTrue(report.contains("尝试 2，未完成 2")); XCTAssertTrue(report.contains("收到回应 1/2（50.0%）")); XCTAssertTrue(report.contains("超时 1/2（50.0%）"))
        XCTAssertTrue(report.contains("不是丢包率"))
    }
    func testAnonymousReportOmitsEveryRawIdentityAndError() {
        var p = probe(); p.name = "secret-name"; p.targetID = "secret-target"; p.url = "https://secret-host.example/private?q=secret-query"
        p.pathID = "secret-path"; p.group = "secret-group"; p.address = "192.168.97.33"; p.error = "secret-error"; p.route = "secret-route"
        var f = frame([p]); f.local.proxySummary = "secret-proxy"; f.local.trafficAdapterID = "secret-adapter"; f.local.trafficAdapterName = "secret-interface"; f.local.gateway = "192.168.97.1"
        var a = AdapterInfo(); a.mac = "aa:bb:cc:dd:ee:ff"; a.name = "secret-local"; f.local.adapters = [a]
        f.findings = [Finding(title: "secret-finding", evidence: "secret-evidence")]
        let report = Diagnostics.buildReport(frames: [f], anonymized: true)
        for secret in ["secret-", "192.168.97", "aa:bb:cc:dd:ee:ff"] { XCTAssertFalse(report.contains(secret), secret) }
        XCTAssertTrue(report.contains("目标1")); XCTAssertTrue(report.contains("自定义组"))
        XCTAssertTrue(Diagnostics.buildReport(frames: [f], anonymized: false).contains("secret-host"))
    }
    func testHistoricURLAndPathHaveSeparateAliases() {
        let a = probe(-60); var b = probe(-30); b.url = "https://changed.example/"; let c = probe(path: "office")
        let report = Diagnostics.buildReport(frames: [frame([a,b,c])], anonymized: true)
        XCTAssertTrue(report.contains("目标1")); XCTAssertTrue(report.contains("目标2")); XCTAssertTrue(report.contains("目标3"))
    }
    func testWarmupAndInvalidRatesStayUnknown() {
        var f = frame([]); f.local.trafficRateReady = false; f.local.downloadBps = 999
        let report = Diagnostics.buildReport(frames: [f], anonymized: true)
        XCTAssertTrue(report.contains("下载峰值 未知")); XCTAssertTrue(report.contains("不能当作零")); XCTAssertFalse(report.contains("999"))
        f.local.trafficRateReady = true; f.local.downloadBps = .infinity; f.local.uploadBps = -1
        XCTAssertTrue(Diagnostics.buildReport(frames: [f], anonymized: true).contains("有效下载采样 0 次"))
    }
    func testHistoryGapReportsActualSamplesOnly() {
        let report = Diagnostics.buildReport(frames: [frame([probe(-3600)], seconds: -3600),frame([probe()])], anonymized: true)
        XCTAssertTrue(report.contains("实际采样 2 轮")); XCTAssertTrue(report.contains("最大间隔 3600 秒"))
    }
    func testEmptyHistoryExplicitlyUnknown() {
        XCTAssertTrue(Diagnostics.buildReport(frames: [], anonymized: true).contains("实际采样 0 轮"))
        XCTAssertTrue(has(result([]), "probes:empty"))
    }
    func testAnonymousReportTruncatesOnlyAtCompleteLinesAndDisclosesOmission() {
        let probes = (0..<100).map { probe(id: "target\($0)") }
        let report = Diagnostics.buildReport(frames: [frame(probes)], anonymized: true)
        XCTAssertLessThanOrEqual(report.count, 8000)
        XCTAssertTrue(report.contains("因长度限制省略")); XCTAssertTrue(report.contains("不能理解成正常"))
        XCTAssertTrue(report.hasSuffix("邻居记录不能说明别的设备占了多少网速。"))
    }
    func testPercentilesUseFiniteNonnegativeObservations() {
        XCTAssertEqual(Diagnostics.percentile([100,200,300,400], 0.5), 250)
        XCTAssertEqual(Diagnostics.percentile([100,200,300,400], 0.95) ?? 0, 385, accuracy: 0.00001)
        XCTAssertEqual(Diagnostics.percentile([.nan,.infinity,-1,100], 0.5), 100)
        XCTAssertNil(Diagnostics.percentile([], 0.5))
    }
}

