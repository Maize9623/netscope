import Foundation
import XCTest
@testable import NetScope

final class ProcessMonitorTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let header = "time,process,bytes_in,bytes_out\n"
    func testTwoSamplesProduceByteRatesAndObservedShares() {
        let sample = ProcessMonitor.parse(header+"12:00:00,App.42,100,200\n12:00:00,VPN.8,500,500\n12:00:02,App.42,500,300\n12:00:02,VPN.8,900,600", at: at)
        XCTAssertEqual(sample.state, "measured"); XCTAssertEqual(sample.intervalSeconds, 2); XCTAssertEqual(sample.rows.count, 2)
        XCTAssertTrue(sample.rows.allSatisfy { $0.downloadBps == 200 && $0.uploadBps == 50 && $0.observedSharePercent == 50 })
        XCTAssertTrue(sample.note.contains("不是占满宽带的比例")); XCTAssertTrue(sample.note.contains("可能重复计算"))
    }
    func testCounterResetIsUnknownNotZero() {
        let sample = ProcessMonitor.parse(header+"12:00:00,App.42,100,200\n12:00:01,App.42,90,300", at: at)
        XCTAssertEqual(sample.state, "unknown"); XCTAssertTrue(sample.rows.isEmpty)
    }
    func testNonnumericCountersAreUnknown() {
        for value in ["2 KiB","-1","nan",""] {
            let sample = ProcessMonitor.parse(header+"12:00:00,App.42,100,200\n12:00:01,App.42,"+value+",300", at: at)
            XCTAssertEqual(sample.state, "unknown"); XCTAssertTrue(sample.rows.isEmpty)
        }
    }
    func testMidnightRolloverIsOneSecond() {
        let sample = ProcessMonitor.parse(header+"23:59:59,App.42,100,200\n00:00:00,App.42,300,250", at: at)
        XCTAssertEqual(sample.intervalSeconds, 1); XCTAssertEqual(sample.rows.first?.downloadBps, 200)
    }
    func testMissingSecondSampleAndLongGapAreUnknown() {
        for body in ["12:00:00,App.42,100,200", "12:00:00,App.42,100,200\n12:01:00,App.42,300,300", ""] {
            let sample = ProcessMonitor.parse(header+body, at: at); XCTAssertEqual(sample.state, "unknown"); XCTAssertTrue(sample.rows.isEmpty)
        }
    }
    func testPIDNameChangeIsNotMergedIntoOldProcess() {
        let sample = ProcessMonitor.parse(header+"12:00:00,Old.42,100,200\n12:00:01,New.42,300,300", at: at)
        XCTAssertEqual(sample.state, "unknown"); XCTAssertTrue(sample.rows.isEmpty)
    }
    func testNewProcessProducesPartialNotInventedRate() {
        let sample = ProcessMonitor.parse(header+"12:00:00,App.42,100,200\n12:00:01,App.42,300,300\n12:00:01,New.43,500,500", at: at)
        XCTAssertEqual(sample.state, "partial"); XCTAssertEqual(sample.rows.count, 1); XCTAssertEqual(sample.rows.first?.pid, 42)
    }
    func testUnchangedObservedCounterIsRealZero() {
        let sample = ProcessMonitor.parse(header+"12:00:00,App.42,100,200\n12:00:01,App.42,100,200", at: at)
        XCTAssertEqual(sample.state, "measured"); XCTAssertEqual(sample.rows.first?.downloadBps, 0); XCTAssertEqual(sample.rows.first?.observedSharePercent, 0)
    }
}
