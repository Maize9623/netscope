import Foundation
import XCTest
@testable import NetScope

final class AIReportTests: XCTestCase {
    private func object() -> [String: Any] {
        ["Summary":"目前还判断不出来", "Status":"uncertain", "PrimaryCause":"需要再观察几次", "Confidence":"low",
         "Evidence":[["Metric":"检查次数","Value":"1","Meaning":"样本还少"]],
         "Alternatives":["本机","当前网络","应用服务"].map { ["Cause":$0,"Confidence":"low","Assessment":"unknown","Reason":"缺少足够测量"] },
         "NextSteps":["稍后再检查一次"], "Details":"未验证生成内容。"]
    }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    func testValidReportAndSchema() throws {
        XCTAssertEqual(try AIReport.parse(data(object())).status, "uncertain")
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AIReport.schema.utf8)) as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual((schema["required"] as? [String])?.count, 8)
        func inspect(_ node: Any) {
            if let item = node as? [String: Any] {
                if item["type"] as? String == "object" { XCTAssertEqual(item["additionalProperties"] as? Bool, false); XCTAssertEqual(Set(item["required"] as? [String] ?? []), Set((item["properties"] as? [String: Any] ?? [:]).keys)) }
                XCTAssertNil(item["maxLength"])
                for value in item.values { inspect(value) }
            } else if let list = node as? [Any] { list.forEach(inspect) }
        }
        inspect(schema)
    }
    func testMarkdownOrProseIsNotExtractedAsJSON() throws {
        let json = String(decoding: try data(object()), as: UTF8.self)
        for text in ["```json\n"+json+"\n```", "Here is the report: "+json, json+" trailing"] { XCTAssertThrowsError(try AIReport.parse(Data(text.utf8))) }
    }
    func testUnknownAndMissingFieldsAreRejected() throws {
        var unknown = object(); unknown["Invented"] = 1; XCTAssertThrowsError(try AIReport.parse(data(unknown)))
        var missing = object(); missing.removeValue(forKey: "Confidence"); XCTAssertThrowsError(try AIReport.parse(data(missing)))
        var nested = object(); nested["Evidence"] = [["Metric":"n","Value":"1","Meaning":"n","Private":"secret"]]; XCTAssertThrowsError(try AIReport.parse(data(nested)))
    }
    func testEnumsAndTypesAreStrict() throws {
        for (key,value) in [("Status","healthy"),("Confidence","99%"),("Summary","")] {
            var invalid = object(); invalid[key] = value; XCTAssertThrowsError(try AIReport.parse(data(invalid)))
        }
        var invalid = object(); invalid["Summary"] = true; XCTAssertThrowsError(try AIReport.parse(data(invalid)))
    }
    func testArrayBoundsAndBlankStepsAreRejected() throws {
        var invalid = object(); invalid["Alternatives"] = []; XCTAssertThrowsError(try AIReport.parse(data(invalid)))
        invalid = object(); invalid["NextSteps"] = ["1","2","3","4"]; XCTAssertThrowsError(try AIReport.parse(data(invalid)))
        invalid = object(); invalid["NextSteps"] = ["   "]; XCTAssertThrowsError(try AIReport.parse(data(invalid)))
        invalid = object(); invalid["Evidence"] = Array(repeating: ["Metric":"m","Value":"v","Meaning":"x"], count: 7); XCTAssertThrowsError(try AIReport.parse(data(invalid)))
    }
    func testDuplicateRootAndEscapedKeysAreRejected() throws {
        let json = String(decoding: try data(object()), as: UTF8.self)
        let ordinary = json.replacingOccurrences(of: "\"Summary\":", with: "\"Summary\":\"conflict\",\"Summary\":")
        let escaped = json.replacingOccurrences(of: "\"Summary\":", with: "\"\\u0053ummary\":\"conflict\",\"Summary\":")
        XCTAssertThrowsError(try AIReport.parse(Data(ordinary.utf8))); XCTAssertThrowsError(try AIReport.parse(Data(escaped.utf8)))
    }
    func testDuplicateNestedKeysAreRejected() throws {
        let json = String(decoding: try data(object()), as: UTF8.self).replacingOccurrences(of: "\"Metric\":", with: "\"Metric\":\"conflict\",\"Metric\":")
        XCTAssertThrowsError(try AIReport.parse(Data(json.utf8)))
    }
    func testStrictJSONRejectsNonJSONAndAcceptsEscapedContent() throws {
        for text in ["{a:1}", "{'a':1}", "{\"a\":1,}", "[1,]", "[01]", "[1.]", "[+1]", "[NaN]", "/*x*/{}", "{\"a\":true,\"a\":false}"] { XCTAssertThrowsError(try StrictJSON.validate(Data(text.utf8)), text) }
        for text in [#"{"text":"quote: \" and braces: {} and slash: \\"}"#, #"[-1.2e+3,true,false,null,[],{}]"#] { XCTAssertNoThrow(try StrictJSON.validate(Data(text.utf8)), text) }
    }
    func testDeepOrOversizedReportsRejected() {
        XCTAssertThrowsError(try StrictJSON.validate(Data((String(repeating: "[", count: 65)+"0"+String(repeating: "]", count: 65)).utf8)))
        XCTAssertThrowsError(try AIReport.parse(Data(repeating: 0x20, count: 131_073)))
    }
}

final class QuotaClientTests: XCTestCase {
    private func bucket(_ used: Any = 37) -> [String: Any] { ["planType":"pro", "primary":["usedPercent":used,"windowDurationMins":300,"resetsAt":1_800_000_000]] }
    func testUsedAndRemainingAreNotSwapped() {
        let value = QuotaClient.parse(["rateLimits":bucket()])
        XCTAssertEqual(value.windows.first?.usedPercent, 37); XCTAssertEqual(value.windows.first?.remainingPercent, 63)
        XCTAssertEqual(value.windows.first?.windowMinutes, 300); XCTAssertEqual(value.plan, "pro")
    }
    func testMultiBucketMapTakesPrecedenceOverLegacy() {
        let value = QuotaClient.parse(["rateLimits":bucket(99),"rateLimitsByLimitId":["codex":bucket(10),"other":bucket(25)]])
        XCTAssertEqual(value.windows.count, 2); XCTAssertEqual(Set(value.windows.map(\.usedPercent)), Set([10.0, 25.0]))
    }
    func testEmptyMapFallsBackToLegacy() { XCTAssertEqual(QuotaClient.parse(["rateLimitsByLimitId":[:],"rateLimits":bucket()]).windows.count, 1) }
    func testMissingValuesAreUnknownNotZero() {
        let value = QuotaClient.parse([:]); XCTAssertTrue(value.windows.isEmpty); XCTAssertNil(value.resetCreditsAvailable); XCTAssertNil(value.resetCreditExpiresAt)
        XCTAssertNil(value.hasCredits); XCTAssertNil(value.creditBalance); XCTAssertNil(value.unlimitedCredits)
        XCTAssertTrue(value.status.contains("不知道"))
    }
    func testBooleansAndStringsCannotBecomeNumbers() {
        let invalidValues: [Any] = [true, false, "20", NSNull()]
        for value in invalidValues { XCTAssertNil(QuotaClient.number(value)); XCTAssertTrue(QuotaClient.parse(["rateLimits":bucket(value)]).windows.isEmpty) }
        XCTAssertNil(QuotaClient.integer(2.5)); XCTAssertNil(QuotaClient.integer(-1)); XCTAssertNil(QuotaClient.number(Double.infinity))
    }
    func testPercentRemainingClampsAtZero() {
        XCTAssertEqual(QuotaClient.parse(["rateLimits":bucket(130)]).windows.first?.remainingPercent, 0)
        XCTAssertTrue(QuotaClient.parse(["rateLimits":bucket(-1)]).windows.isEmpty)
    }
    func testAbsentResetAndDurationStayNil() {
        let value = QuotaClient.parse(["rateLimits":["primary":["usedPercent":25]]])
        XCTAssertNil(value.windows.first?.resetAt); XCTAssertNil(value.windows.first?.windowMinutes)
    }
    func testResetCreditOnlyUsesAvailableMatchingTypeAndEarliestExpiry() {
        let rows: [[String: Any]] = [
            ["status":"available","resetType":"codexRateLimits","expiresAt":1_800_000_050],
            ["status":"available","resetType":"codexRateLimits","expiresAt":1_800_000_020],
            ["status":"used","resetType":"codexRateLimits","expiresAt":1_800_000_001],
            ["status":"available","resetType":"other","expiresAt":1_800_000_000]]
        let value = QuotaClient.parse(["rateLimitResetCredits":["availableCount":2,"credits":rows]])
        XCTAssertEqual(value.resetCreditsAvailable, 2); XCTAssertEqual(value.resetCreditExpiresAt?.timeIntervalSince1970, 1_800_000_020)
    }
    func testNumericFlagsDoNotBecomeCreditBooleans() {
        let value = QuotaClient.parse(["rateLimits":["credits":["hasCredits":1,"unlimited":0]]])
        XCTAssertNil(value.hasCredits); XCTAssertNil(value.unlimitedCredits)
    }
    func testReadOnlyCreditMetadataPreservesUnknownBalanceUnit() {
        let value = QuotaClient.parse(["rateLimits":["credits":["hasCredits":true,"unlimited":false,"balance":"12.34"]]])
        XCTAssertEqual(value.creditBalance, "12.34"); XCTAssertEqual(value.hasCredits, true); XCTAssertEqual(value.unlimitedCredits, false)
    }
}

