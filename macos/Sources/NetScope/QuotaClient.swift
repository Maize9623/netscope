import Foundation
import CoreFoundation

struct QuotaWindow: Codable, Identifiable {
    var name: String; var usedPercent: Double; var remainingPercent: Double; var resetAt: Date?; var windowMinutes: Int?
    var id: String { name }
}
struct QuotaSnapshot: Codable {
    var at = Date(); var windows: [QuotaWindow] = []; var plan: String?; var creditBalance: String?
    var hasCredits: Bool?; var unlimitedCredits: Bool?; var resetCreditsAvailable: Int?; var resetCreditExpiresAt: Date?
    var status = "已读取账号共享额度"
}
enum QuotaClient {
    static func fetch(codexPath: String?) async throws -> QuotaSnapshot {
        let path = try CodexCommand.locate(codexPath)
        let initialize: [String: Any] = ["id":1,"method":"initialize","params":["clientInfo":["name":"netscope","version":"0.1.0"],"capabilities":["experimentalApi":true,"explicitGatewayOauth":true]]]
        var initial = try JSONSerialization.data(withJSONObject: initialize); initial.append(10)
        let result = try await CodexCommand.run(path: path, arguments: ["app-server","--stdio","-c","analytics.enabled=false"], input: initial, timeout: 18) { line, stdin in
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], event["method"] == nil, let id = integer(event["id"]) else { return false }
            if id == 1 {
                if event["error"] != nil || event["result"] == nil { return true }
                let requests: [[String: Any]] = [["method":"initialized","params":[:]], ["id":2,"method":"account/rateLimits/read","params":["excludeResetCreditDetails":false]]]
                for request in requests {
                    if var data = try? JSONSerialization.data(withJSONObject: request) { data.append(10); try? stdin.write(contentsOf: data) }
                }
            }
            return id == 2
        }
        for line in result.stdout.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], integer(event["id"]) == 2 else { continue }
            guard event["error"] == nil, let object = event["result"] as? [String: Any] else { throw CodexClientError.quotaFailed }
            return parse(object)
        }
        throw CodexClientError.quotaFailed
    }
    static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    static func integer(_ raw: Any?) -> Int? {
        guard let value = number(raw), value >= 0, value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    static func parse(_ root: [String: Any]) -> QuotaSnapshot {
        var result = QuotaSnapshot()
        var buckets = (root["rateLimitsByLimitId"] as? [String: [String: Any]]) ?? [:]
        if buckets.isEmpty, let legacy = root["rateLimits"] as? [String: Any] { buckets["codex"] = legacy }
        func date(_ raw: Any?) -> Date? { guard let seconds = number(raw), seconds >= 0, seconds < 253_402_300_800 else { return nil }; return Date(timeIntervalSince1970: seconds) }
        for key in buckets.keys.sorted(by: { ($0 == "codex" ? "0" : "1"+$0) < ($1 == "codex" ? "0" : "1"+$1) }) {
            guard let bucket = buckets[key] else { continue }
            let label = (bucket["limitName"] as? String) ?? (bucket["normalModelSlug"] as? String) ?? (bucket["limitId"] as? String) ?? key
            for role in ["primary","secondary"] {
                guard let window = bucket[role] as? [String: Any], let used = number(window["usedPercent"]), used >= 0 else { continue }
                let minutes = integer(window["windowDurationMins"]).flatMap { $0 > 0 ? $0 : nil }
                let name: String
                if let minutes { name = minutes % 1440 == 0 ? "\(minutes/1440) 天" : minutes % 60 == 0 ? "\(minutes/60) 小时" : "\(minutes) 分钟" }
                else { name = role == "primary" ? "主周期" : "另一周期" }
                result.windows.append(QuotaWindow(name: label+" · "+name, usedPercent: used, remainingPercent: min(100,max(0,100-used)), resetAt: date(window["resetsAt"]), windowMinutes: minutes))
            }
            if result.plan == nil { result.plan = bucket["planType"] as? String }
            if let credits = bucket["credits"] as? [String: Any] {
                if result.creditBalance == nil { result.creditBalance = credits["balance"] as? String }
                if result.hasCredits == nil { result.hasCredits = boolean(credits["hasCredits"]) }
                if result.unlimitedCredits == nil { result.unlimitedCredits = boolean(credits["unlimited"]) }
            }
        }
        if let resets = root["rateLimitResetCredits"] as? [String: Any] {
            result.resetCreditsAvailable = integer(resets["availableCount"])
            for credit in resets["credits"] as? [[String: Any]] ?? [] where credit["status"] as? String == "available" && credit["resetType"] as? String == "codexRateLimits" {
                if let expires = date(credit["expiresAt"]), result.resetCreditExpiresAt == nil || expires < result.resetCreditExpiresAt! { result.resetCreditExpiresAt = expires }
            }
        }
        if boolean(root["ordinaryUsageAllowed"]) == false { result.status = "账号当前的普通包含额度不可用" }
        else if result.windows.isEmpty { result.status = "账号未提供额度百分比，暂时不知道还剩多少" }
        return result
    }
    private static func boolean(_ value: Any?) -> Bool? { guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue }
}
