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
        let result=try await CodexCommand.run(path:"/usr/bin/nettop",arguments:["-P","-L","2","-s","1","-n","-x","-J","bytes_in,bytes_out"],input:Data(),timeout:8)
        guard result.exitCode == 0 else { throw XCTSkip("macOS runner did not allow nettop") }
        let snapshot=ProcessMonitor.parse(result.stdout)
        XCTAssertNotEqual(snapshot.state,"unknown",String(result.stdout.prefix(3000)))
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.downloadBps >= 0 && $0.uploadBps >= 0 })
    }
}
