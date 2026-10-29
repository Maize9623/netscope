import Foundation
import XCTest
@testable import NetScope

final class StoreAndDeviceTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDeviceLabelsPersistAndClearWithoutConflatingSameNames() throws {
        let url = try temporary(), store = try LocalStore(baseURL: url)
        try store.saveDeviceLabel(mac: "aa:bb:cc:dd:ee:01", label: "同名设备")
        try store.saveDeviceLabel(mac: "aa:bb:cc:dd:ee:02", label: "同名设备")
        let reopened = try LocalStore(baseURL: url)
        XCTAssertEqual(try reopened.loadDeviceLabels().count, 2)
        try reopened.saveDeviceLabel(mac: "aa:bb:cc:dd:ee:01", label: "  ")
        let remaining = try reopened.loadDeviceLabels()
        XCTAssertNil(remaining["aa:bb:cc:dd:ee:01"]); XCTAssertEqual(remaining["aa:bb:cc:dd:ee:02"], "同名设备")
    }
    func testHistorySurvivesRestartAndCorruptTailAppend() throws {
        let url = try temporary(), store = try LocalStore(baseURL: url)
        var first = MonitorFrame(); first.at = Date(timeIntervalSince1970: 1_800_000_000); first.local.at = first.at
        try store.append(frame: first)
        let files = try FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("history"), includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first), handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        var second = first; second.at = first.at.addingTimeInterval(30); second.local.at = second.at
        try store.append(frame: second)
        let reopened = try LocalStore(baseURL: url), loaded = try reopened.loadHistory()
        XCTAssertEqual(loaded.count, 2); XCTAssertEqual(loaded.last?.at, second.at); XCTAssertFalse(reopened.recoveryWarnings.isEmpty)
    }
    func testSettingsRejectCredentialURLsWithoutReplacingLastGoodFile() throws {
        let store = try LocalStore(baseURL: temporary()); var valid = AppSettings(); valid.aiAutoEnabled = false
        try store.saveSettings(valid)
        var invalid = valid; invalid.targets = [ProbeTarget(name: "bad", url: "https://user:password@example.com/")]
        XCTAssertThrowsError(try store.saveSettings(invalid)); XCTAssertFalse(try store.loadSettings().aiAutoEnabled)
        XCTAssertNotEqual(try store.loadSettings().targets.first?.name, "bad")
    }
    func testSettingsRecoverLastKnownGoodBackup() throws {
        let url = try temporary(), store = try LocalStore(baseURL: url); var settings = AppSettings(); settings.intervalSeconds = 20
        try store.saveSettings(settings); settings.intervalSeconds = 40; try store.saveSettings(settings)
        try Data("{broken".utf8).write(to: url.appendingPathComponent("settings.json"))
        XCTAssertEqual(try LocalStore(baseURL: url).loadSettings().intervalSeconds, 20)
    }
    func testNeighbourRecordsDoNotInventDeviceTypesOrRates() {
        let arp = DeviceCollector.parseARP("? (192.0.2.10) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]\n? (192.0.2.11) at (incomplete) on en0")
        XCTAssertEqual(arp.count, 2); XCTAssertEqual(arp.first?.name, "未知"); XCTAssertNil(arp.first?.downloadBps)
        XCTAssertTrue(arp.first?.hint.contains("类型未知") == true)
        let ndp = DeviceCollector.parseNDP("fe80::1%en0 aa:bb:cc:dd:ee:ff en0 23h59m S")
        XCTAssertEqual(ndp.count, 1); XCTAssertNil(ndp.first?.uploadBps)
    }
    func testCSVParserPreservesQuotedFieldsAndRejectsMalformedRecords() throws {
        XCTAssertEqual(try DeviceCollector.parseCSV("ip,name\n192.0.2.1,\"x,y\""), [["ip","name"],["192.0.2.1","x,y"]])
        for text in ["ip,name\n1,\"broken", "ip,name\n1,\"closed\"suffix"] { XCTAssertThrowsError(try DeviceCollector.parseCSV(text)) }
    }
    func testHTTPClassifierAndDurationMeaning() {
        XCTAssertEqual(BackendHTTP.classify(status: 407).0, .proxyAuthRequired)
        XCTAssertEqual(BackendHTTP.classify(status: 401).0, .authRequired)
        XCTAssertEqual(BackendHTTP.classify(status: 429).0, .rateLimited)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNil(BackendHTTP.milliseconds(nil, start)); XCTAssertNil(BackendHTTP.milliseconds(start, start.addingTimeInterval(-1)))
        XCTAssertEqual(BackendHTTP.milliseconds(start, start.addingTimeInterval(0.25)), 250)
    }
}
