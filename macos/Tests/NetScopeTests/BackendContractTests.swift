import Foundation
import XCTest
@testable import NetScope

final class BackendContractTests: XCTestCase {
    func testCounterRateUsesBytesAndActualElapsedTime() {
        let rate = BackendMath.counterRates(previousReceived: 1000, previousSent: 2000, received: 5096, sent: 3024, elapsed: 2)
        XCTAssertEqual(rate.download, 2048); XCTAssertEqual(rate.upload, 512)
    }
    func testInitialCounterSampleIsUnknown() {
        let rate = BackendMath.counterRates(previousReceived: nil, previousSent: nil, received: 1000, sent: 1000, elapsed: 2)
        XCTAssertNil(rate.download); XCTAssertNil(rate.upload)
    }
    func testCounterResetIsUnknownNotNegativeOrOverflow() {
        let rate = BackendMath.counterRates(previousReceived: 1000, previousSent: 2000, received: 900, sent: 2100, elapsed: 2)
        XCTAssertNil(rate.download); XCTAssertNil(rate.upload)
    }
    func testSleepAndInvalidElapsedTimeDoNotTurnIntoZero() {
        for seconds in [0, -1, 0.01, 11, 3600, Double.nan, Double.infinity] {
            let rate = BackendMath.counterRates(previousReceived: 1000, previousSent: 1000, received: 2000, sent: 2000, elapsed: seconds)
            XCTAssertNil(rate.download); XCTAssertNil(rate.upload)
        }
    }
    func testObservedUnchangedCountersAreValidZero() {
        let rate = BackendMath.counterRates(previousReceived: 1000, previousSent: 1000, received: 1000, sent: 1000, elapsed: 2)
        XCTAssertEqual(rate.download, 0); XCTAssertEqual(rate.upload, 0)
    }
    func testURLAddsHTTPSAndKeepsSafeExplicitSchemes() {
        XCTAssertEqual(BackendValidation.targetURL(" example.com/path ")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BackendValidation.targetURL("http://example.com/")?.scheme, "http")
        XCTAssertNotNil(BackendValidation.targetURL("https://example.com/path?q=hello"))
    }
    func testURLRejectsCredentialsAndUnsafeSchemes() {
        for value in ["https://user:password@example.com/", "https://user@example.com/", "ftp://example.com/", "file:///etc/passwd", "https://", "", "https://exa mple.com/", "https://example.com/\nsecret"] {
            XCTAssertNil(BackendValidation.targetURL(value), value)
        }
    }
    func testCSVQuotesEmbeddedSeparatorsAndQuotes() {
        XCTAssertEqual(BackendCSV.escape("a,b\"c\nline"), "\"a,b\"\"c\nline\"")
    }
    func testCSVNeutralizesFormulaPrefixesAfterWhitespace() {
        for value in ["=1+1", "+cmd", "-1", "@SUM(A1)", " \t=1", "\n+cmd"] {
            XCTAssertTrue(BackendCSV.escape(value).hasPrefix("\"'"), value)
        }
        XCTAssertEqual(BackendCSV.escape("正常标签"), "\"正常标签\"")
    }
    func testConfigurationClampsOutOfRangeValuesAndPreservesAIFalse() throws {
        let json = #"{"intervalSeconds":0,"timeoutSeconds":999,"retentionDays":-3,"aiAutoEnabled":false,"aiIntervalMinutes":0,"maxAiCallsPerDay":-9}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.intervalSeconds, 15); XCTAssertEqual(settings.timeoutSeconds, 20); XCTAssertEqual(settings.retentionDays, 1)
        XCTAssertFalse(settings.aiAutoEnabled); XCTAssertEqual(settings.aiIntervalMinutes, 5); XCTAssertEqual(settings.maxAiCallsPerDay, 0)
        let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(roundtrip.aiAutoEnabled); XCTAssertEqual(roundtrip.maxAiCallsPerDay, 0)
    }
    func testOldSettingsUseDefaultsForMissingFields() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.intervalSeconds, 30); XCTAssertFalse(settings.targets.isEmpty)
    }
    func testMACNormalizationDoesNotGuessInvalidValues() {
        XCTAssertEqual(BackendValidation.normalizedMAC("AA-BB-CC-DD-EE-FF"), "aa:bb:cc:dd:ee:ff")
        XCTAssertNil(BackendValidation.normalizedMAC("not-a-device")); XCTAssertNil(BackendValidation.normalizedMAC("aa:bb:cc"))
    }
    func testMACSingleDigitOctetsAndEmptyGroups() {
        XCTAssertEqual(BackendValidation.normalizedMAC("a:b:c:d:e:f"), "0a:0b:0c:0d:0e:0f")
        XCTAssertNil(BackendValidation.normalizedMAC("aa::bb:cc:dd:ee:ff"))
        XCTAssertNil(BackendValidation.normalizedMAC(":aa:bb:cc:dd:ee:ff"))
    }
    func testNetworkFingerprintIgnoresOrderingAndCounters() {
        var a = AdapterInfo(id: "en0", isUp: true, addresses: ["192.168.1.2", "fe80::1"],
                            gateways: ["192.168.1.1"], dnsServers: ["1.1.1.1", "8.8.8.8"])
        let b = AdapterInfo(id: "utun0", isVirtual: true, isUp: true, addresses: ["10.0.0.2"])
        let metadata = SystemNetworkMetadata(primaryInterface: "en0")
        let first = NetworkPathContext.make(selectedAdapterID: "en0", adapters: [a, b], metadata: metadata)
        a.addresses.reverse(); a.dnsServers.reverse(); a.receivedBytes = 9000; a.downloadBps = 500
        XCTAssertEqual(first, NetworkPathContext.make(selectedAdapterID: "en0", adapters: [b, a], metadata: metadata))
    }
    func testNetworkFingerprintChangesWithAddressGatewayAndDNS() {
        let base = AdapterInfo(id: "en0", isUp: true, addresses: ["192.168.1.2"],
                               gateways: ["192.168.1.1"], dnsServers: ["1.1.1.1"])
        let metadata = SystemNetworkMetadata(primaryInterface: "en0")
        let fingerprint = NetworkPathContext.make(selectedAdapterID: "en0", adapters: [base], metadata: metadata)
        for field in 0..<3 {
            var changed = base
            if field == 0 { changed.addresses = ["192.168.2.2"] }
            if field == 1 { changed.gateways = ["192.168.2.1"] }
            if field == 2 { changed.dnsServers = ["8.8.8.8"] }
            XCTAssertNotEqual(fingerprint, NetworkPathContext.make(selectedAdapterID: "en0", adapters: [changed], metadata: metadata))
        }
    }
    func testNetworkFingerprintSeparatesProxyAndSelection() {
        let adapter = AdapterInfo(id: "en0", isUp: true)
        var metadata = SystemNetworkMetadata(primaryInterface: "en0", proxySummary: "direct")
        let fingerprint = NetworkPathContext.make(selectedAdapterID: "en0", adapters: [adapter], metadata: metadata)
        metadata.proxySummary = "HTTPS proxy"
        XCTAssertNotEqual(fingerprint, NetworkPathContext.make(selectedAdapterID: "en0", adapters: [adapter], metadata: metadata))
        metadata.proxySummary = "direct"
        XCTAssertNotEqual(fingerprint, NetworkPathContext.make(selectedAdapterID: "utun0", adapters: [adapter], metadata: metadata))
    }
    func testConfigurationUpperBoundsMatchUI() throws {
        let json = #"{"retentionDays":365,"maxAiCallsPerDay":1000,"timeoutSeconds":1}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.retentionDays, 90); XCTAssertEqual(settings.maxAiCallsPerDay, 200)
        XCTAssertEqual(settings.timeoutSeconds, 3)
    }
}
