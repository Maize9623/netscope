import Foundation

/// A single HEAD transaction. Cancellation and the deadline always resume the
/// continuation once, then invalidate this task's private ephemeral session.
final class HTTPHeadProbe: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let target: ProbeTarget
    private let timeout: TimeInterval
    private let context: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProbeResult, Never>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var cancelled = false
    private var started: UInt64 = 0
    private var result: ProbeResult
    private var proxyChallenge = false

    init(target: ProbeTarget, timeout: TimeInterval, context: String) {
        self.target = target; self.timeout = timeout; self.context = context
        result = ProbeResult(at: Date(), targetID: target.id, name: target.name, group: target.group, url: target.url)
        super.init()
    }

    func run() async -> ProbeResult {
        guard let url = BackendValidation.targetURL(target.url) else {
            var answer = result; answer.outcome = .invalidURL
            answer.error = "须为有效HTTP(S)地址且不得含用户名或密码；省略协议按HTTPS处理"
            return answer
        }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { promise in
                lock.lock(); continuation = promise; let alreadyCancelled = cancelled; lock.unlock()
                if alreadyCancelled || Task.isCancelled { finish(forced: .skipped, message: "本轮探测已取消"); return }
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
                config.waitsForConnectivity = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.httpMaximumConnectionsPerHost = 4
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let current = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                request.httpMethod = "HEAD"; request.setValue("NetScope-macOS/1.0", forHTTPHeaderField: "User-Agent")
                let newTask = current.dataTask(with: request)
                let limit = DispatchWorkItem { [weak self] in self?.finish(forced: .timeout, message: "HTTP响应头超过设定时限；已取消本轮请求") }
                lock.lock()
                guard continuation != nil else { lock.unlock(); current.invalidateAndCancel(); return }
                result.url = url.absoluteString; session = current; task = newTask; deadline = limit
                started = DispatchTime.now().uptimeNanoseconds
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: limit)
                newTask.resume()
            }
        }, onCancel: {
            self.lock.lock(); self.cancelled = true; self.lock.unlock()
            self.finish(forced: .skipped, message: "本轮探测已取消")
        })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if let http = response as? HTTPURLResponse {
            result.statusCode = http.statusCode
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= started { result.httpMs = Double(now - started) / 1_000_000 }
        }
        lock.unlock(); completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); result.statusCode = response.statusCode
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= started { result.httpMs = Double(now - started) / 1_000_000 }
        lock.unlock(); completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock(); proxyChallenge = challenge.protectionSpace.isProxy(); lock.unlock()
        // Preserve system certificate validation. Never submit a credential.
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        lock.lock()
        result.dnsMs = BackendHTTP.milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        result.tcpMs = BackendHTTP.milliseconds(transaction.connectStartDate, transaction.secureConnectionStartDate ?? transaction.connectEndDate)
        result.tlsMs = BackendHTTP.milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        result.isProxyConnection = transaction.isProxyConnection
        result.isReusedConnection = transaction.isReusedConnection
        result.networkProtocol = transaction.networkProtocolName
        result.address = transaction.remoteAddress
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error: error) }

    private func finish(error: Error? = nil, forced: ProbeOutcome? = nil, message: String = "") {
        lock.lock()
        guard let promise = continuation else { lock.unlock(); return }
        continuation = nil; deadline?.cancel(); deadline = nil
        if let status = result.statusCode {
            let classification = BackendHTTP.classify(status: status)
            result.outcome = classification.0; result.error = classification.1; result.reachable = true
        } else if let forced = forced {
            result.outcome = forced; result.error = message
        } else if let failure = error as? URLError {
            switch failure.code {
            case .timedOut: result.outcome = .timeout; result.error = "HTTP事务超时，未取得响应头"
            case .cannotFindHost, .dnsLookupFailed:
                result.outcome = result.isProxyConnection == true ? .proxyError : .dnsError
                result.error = "HTTP事务名称解析失败；可能涉及目标或代理"
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                result.outcome = .connectError; result.error = "HTTP事务连接失败：\(failure.code.rawValue)"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
                result.outcome = .tlsError; result.error = "TLS或证书验证失败；未绕过系统验证"
            case .appTransportSecurityRequiresSecureConnection:
                result.outcome = .error; result.error = "macOS ATS限制此HTTP地址；请改用HTTPS。此结果不是断网证据"
            case .cancelled: result.outcome = .skipped; result.error = "请求已取消，属于缺失测量"
            case .userAuthenticationRequired, .userCancelledAuthentication:
                result.outcome = proxyChallenge ? .proxyError : .error
                result.error = proxyChallenge ? "代理要求认证，尚未验证目标服务" : "认证挑战未完成，不能据此判定网络故障"
            default: result.outcome = .error; result.error = "系统未完成有效测量：URL错误码\(failure.code.rawValue)"
            }
        } else { result.outcome = .error; result.error = error == nil ? "未获得HTTP响应或有效错误信息" : "检测器执行失败：\(type(of: error!))" }
        let proxyText: String
        if let proxy = result.isProxyConnection { proxyText = proxy ? "事务度量确认使用代理" : "事务未报告HTTP代理（仍可能经VPN/TUN）" }
        else { proxyText = "系统未报告本次代理路径" }
        let reused = result.isReusedConnection.map { $0 ? "连接复用" : "新连接" } ?? "连接复用状态未知"
        result.route = "URLSession系统网络路径；\(proxyText)；\(reused)；HTTP为到响应头总耗时，包含代理/DNS/TCP/TLS；DNS/TCP/TLS缺失不代表0，可能是缓存、复用或系统未报告；HTTP响应不代表模型推理或账号可用"
        result.pathID = BackendHTTP.stableID(result.url + "|" + context + "|" + proxyText)
        let answer = result; let active = session; session = nil; task = nil
        lock.unlock()
        active?.invalidateAndCancel(); promise.resume(returning: answer)
    }
}

enum BackendHTTP {
    static func milliseconds(_ start: Date?, _ end: Date?) -> Double? {
        guard let start = start, let end = end else { return nil }
        let value = end.timeIntervalSince(start) * 1000
        return value.isFinite && value >= 0 ? value : nil
    }
    static func classify(status: Int) -> (ProbeOutcome, String) {
        switch status {
        case 200..<300: return (.ok, "")
        case 300..<400: return (.redirect, "收到重定向；未跟随新目标")
        case 401: return (.authRequired, "服务要求认证；仅确认HTTP响应")
        case 403: return (.forbidden, "请求被拒绝；不能仅据此断言地区或权限原因")
        case 404: return (.notFound, "接口路径不存在；已收到HTTP响应")
        case 405: return (.methodNotAllowed, "不接受HEAD；未补发GET")
        case 407: return (.proxyAuthRequired, "代理要求认证，尚未验证目标服务")
        case 429: return (.rateLimited, "请求受限；未验证模型推理或账号额度")
        case 500..<600: return (.serverError, "服务端或中间代理错误；已收到HTTP响应")
        default: return (.httpError, "HTTP状态码\(status)；仅确认收到响应")
        }
    }
    static func stableID(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}
