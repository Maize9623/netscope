import Foundation
import XCTest
@testable import NetScope

/// Checks the meaning of UI state and grouping, without starting AppModel or network work.
final class PresentationTests: XCTestCase {
    private func device(_ address: String = "192.0.2.2", mac: String = "aa:bb:cc:dd:ee:ff", source: String = "macOS ARP缓存 · en0", name: String = "未知") -> DeviceInfo {
        DeviceInfo(ip: address, mac: mac, name: name, source: source)
    }
    private var physical: AdapterInfo { AdapterInfo(id: "en0", name: "Wi-Fi", isVirtual: false, isUp: true) }
    private var virtual: AdapterInfo { AdapterInfo(id: "utun0", name: "VPN", isVirtual: true, isUp: true) }
    private func probe(_ outcome: ProbeOutcome, status: Int? = nil) -> ProbeResult {
        var value = ProbeResult(); value.outcome = outcome; value.statusCode = status; value.reachable = status != nil
        return value
    }
    func testARPSourceMapsToExactPhysicalInterface() {
        XCTAssertEqual(DeviceWorkbench.group(for: device(), adapters: [physical, virtual]), .physical)
    }
    func testNDPSourceMapsToExactVirtualInterface() {
        XCTAssertEqual(DeviceWorkbench.group(for: device("fe80::1%utun0", source: "macOS NDP缓存 · utun0"), adapters: [physical, virtual]), .virtual)
    }
    func testUnmatchedInterfaceStaysUnknown() {
        XCTAssertEqual(DeviceWorkbench.group(for: device(source: "macOS ARP缓存 · en01"), adapters: [physical]), .unknown)
        XCTAssertEqual(DeviceWorkbench.group(for: device(source: "macOS ARP缓存 · en0"), adapters: []), .unknown)
    }
    func testUnknownSourceDoesNotBecomePhysicalFromItsNameOrAddress() {
        XCTAssertEqual(DeviceWorkbench.group(for: device(source: "来源未知", name: "Wi-Fi printer en0"), adapters: [physical]), .unknown)
    }
    func testGatewayImportAlwaysRetainsUnknownNetworkProvenance() {
        XCTAssertEqual(DeviceWorkbench.group(for: device(source: "网关CSV导入", name: "router-en0"), adapters: [physical]), .unknown)
    }
    func testDuplicateAdapterIdentityDoesNotGuessAClassification() {
        var ambiguous = physical; ambiguous.isVirtual = true
        XCTAssertEqual(DeviceWorkbench.group(for: device(), adapters: [physical, ambiguous]), .unknown)
    }
    func testLocalInterfacesAreMergedOnlyWhenExplicitlySelfReported() {
        let first = device(source: "本机接口 / macOS自报"), second = device("fe80::2%en0", source: "本机接口 / macOS自报")
        let neighbour = device("192.0.2.3", source: "macOS ARP缓存 · en0", name: "这台 Mac")
        let rows = DeviceWorkbench.make(devices: [first, second, neighbour], adapters: [physical])
        XCTAssertEqual(rows.localRecords.count, 2); XCTAssertEqual(rows.records(in: .physical).count, 1)
        XCTAssertEqual(rows.records(in: .physical).first?.ip, "192.0.2.3")
    }
    func testSharedMACDoesNotMergeNeighbourIntoThisMac() {
        let local = device(source: "本机接口 / macOS自报"), other = device("192.0.2.3")
        let rows = DeviceWorkbench.make(devices: [local, other], adapters: [physical])
        XCTAssertEqual(rows.localRecords.count, 1); XCTAssertEqual(rows.records(in: .physical).count, 1)
    }
    func testImportedRecordCallingItselfLocalDoesNotBecomeThisMac() {
        let row = device(source: "网关CSV导入", name: "本机 Mac")
        XCTAssertFalse(DeviceWorkbench.isLocal(row))
        XCTAssertEqual(DeviceWorkbench.make(devices: [row], adapters: [physical]).records(in: .unknown).count, 1)
    }
    func testExactDuplicateCacheRowsAreNotRepeated() {
        let row = device(); let result = DeviceWorkbench.make(devices: [row,row], adapters: [physical])
        XCTAssertEqual(result.records(in: .physical).count, 1)
    }
    func testDownInterfaceDoesNotConvertCachedRecordIntoOnlineClaim() {
        var adapter = physical; adapter.isUp = false
        XCTAssertEqual(DeviceWorkbench.group(for: device(), adapters: [adapter]), .physical)
        XCTAssertTrue(DeviceWorkbenchGroup.physical.note.contains("不代表设备现在在线"))
        XCTAssertTrue(DeviceWorkbenchGroup.virtual.note.contains("不一定是另一台物理设备"))
    }
    func testDeviceTypeDoesNotComeFromGatewayProvenanceText() {
        var row = device(source: "网关CSV导入"); row.hint = "网关CSV声明；设备类型未验证"
        XCTAssertEqual(DeviceWorkbench.guess(row), "暂时不知道设备类型")
        XCTAssertEqual(DeviceWorkbench.symbol(row), "questionmark.square.dashed")
    }
    func testUnknownSourceDoesNotClaimToBeACacheOrAnOnlineDevice() {
        let text = DeviceWorkbench.recordStatus(device(source: "来源未知"))
        XCTAssertTrue(text.contains("来源待确认")); XCTAssertFalse(text.contains("缓存记录"))
        XCTAssertTrue(text.contains("当前在线未确认"))
    }    func testStartupDoesNotClaimHealthyOrInventResponses() {
        let state = CheckOverview.make(probes: [], checking: false, hasFrame: false, issueCount: 0)
        XCTAssertEqual(state.title, "现在上网顺不顺？")
        XCTAssertTrue(state.resultLine.contains("还没有"))
    }
    func testOnlyMissingSamplesAreUnknownNotHealthy() {
        let state = CheckOverview.make(probes: [probe(.skipped),probe(.error)], checking: false, hasFrame: true, issueCount: 0)
        XCTAssertTrue(state.title.contains("2 项还没有测到")); XCTAssertTrue(state.note.contains("不能判断"))
    }
    func testProxyAuthenticationDoesNotCountAsApplicationResponse() {
        let state = CheckOverview.make(probes: [probe(.proxyAuthRequired, status: 407)], checking: false, hasFrame: true, issueCount: 1)
        XCTAssertEqual(state.title, "上网通道需要先登录"); XCTAssertTrue(state.attention)
        XCTAssertFalse(state.resultLine.contains("1 个应用有回应"))
    }
    func testUnauthorizedResponseDoesNotClaimLoginOrChatWorks() {
        let state = CheckOverview.make(probes: [probe(.authRequired, status: 401)], checking: false, hasFrame: true, issueCount: 0)
        XCTAssertEqual(state.title, "这次 1 个应用有回应")
        XCTAssertTrue(state.note.contains("登录和聊天")); XCTAssertTrue(state.note.contains("确认"))
    }
    func testFailureCountComesOnlyFromAttemptedTransportFailures() {
        let state = CheckOverview.make(probes: [probe(.timeout),probe(.error),probe(.forbidden, status: 403)], checking: false, hasFrame: true, issueCount: 0)
        XCTAssertEqual(state.title, "有 1 项连接值得检查"); XCTAssertTrue(state.resultLine.contains("1 项有回应"))
    }
    func testHTTPResponseOverridesInconsistentFailureOutcome() {
        let state = CheckOverview.make(probes: [probe(.dnsError, status: 200)], checking: false, hasFrame: true, issueCount: 0)
        XCTAssertEqual(state.title, "这次 1 个应用有回应"); XCTAssertFalse(state.attention)
    }
    func testRateLimitAndServerReplyRemainVisibleAsNotices() {
        for status in [429,503] {
            let state = CheckOverview.make(probes: [probe(.httpError, status: status)], checking: false, hasFrame: true, issueCount: 0)
            XCTAssertTrue(state.attention); XCTAssertTrue(state.title.contains("提示"))
        }
    }
    func testCheckingIsProgressWithoutInventedPercentage() {
        let state = CheckOverview.make(probes: [], checking: true, hasFrame: false, issueCount: 0)
        XCTAssertEqual(state.title, "正在检查当前连接")
        XCTAssertFalse((state.title + state.note + state.resultLine).contains("%"))
    }
}
