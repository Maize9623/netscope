import Foundation
import XCTest
@testable import NetScope

final class MacIntegrationTests: XCTestCase {
    private func requireRunner() throws {
        guard ProcessInfo.processInfo.environment["NETSCOPE_LOCAL_SMOKE"] == "1" else { throw XCTSkip("Opt-in local macOS sampler smoke check") }
    }
    func testRealInterfaceCounters() async throws {
        try requireRunner()
        let monitor=NetworkMonitor()
        _ = await monitor.captureLocal(selectedAdapterID:"auto")
        try await Task.sleep(for:.seconds(1))
        let result=await monitor.captureLocal(selectedAdapterID:"auto")
        XCTAssertFalse(result.adapters.isEmpty)
        XCTAssertTrue(result.adapters.contains { $0.isUp && $0.downloadBps != nil && $0.uploadBps != nil }, "No valid 64-bit rate was available on any live macOS interface")
        XCTAssertTrue(result.adapters.compactMap(\.downloadBps).allSatisfy { $0 >= 0 && $0.isFinite })
    }
    func testRealNettopFormat() async throws {
        try requireRunner()
        let snapshot = try await ProcessMonitor.capture()
        if snapshot.note.contains("不会自动提权") { throw XCTSkip("macOS runner did not allow nettop") }
        XCTAssertTrue(["measured", "partial"].contains(snapshot.state), snapshot.note)
        XCTAssertEqual(snapshot.intervalIsApproximate, true)
        XCTAssertTrue(snapshot.note.contains("收集窗口"), snapshot.note)
        XCTAssertTrue(snapshot.intervalSeconds >= 0.2 && snapshot.intervalSeconds <= 10)
        XCTAssertFalse(snapshot.rows.isEmpty)
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.downloadBps >= 0 && $0.uploadBps >= 0 && $0.receivedBytes != nil && $0.sentBytes != nil })
        print("Nettop real capture: state=\(snapshot.state), rows=\(snapshot.rows.count), window=\(snapshot.intervalSeconds), basis=\(snapshot.timingBasis ?? "unknown")")
    }
}
