import Foundation
import Darwin

enum CodexClientError: LocalizedError {
    case missingCLI, timedOut, analysisFailed, invalidReport, quotaFailed, tooMuchOutput
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "还没有找到 Codex。请先安装并登录 Codex，或在设置里选中它的命令行程序。"
        case .timedOut: return "这次等待太久，已停止请求。网络恢复后可以重试。"
        case .analysisFailed: return "这次 AI 没有返回完整结果。请检查 Codex 登录和网络；本地记录会继续。"
        case .invalidReport: return "AI 回答的格式不完整，暂时不能显示为可靠结论。原始测量不受影响。"
        case .quotaFailed: return "暂时读不到账号额度。请检查 Codex 登录和版本；未知数值不会显示成零。"
        case .tooMuchOutput: return "Codex 返回内容过多，已停止本次请求。"
        }
    }
}
struct CodexCommandResult { let stdout: String; let exitCode: Int32 }
private final class CommandCapture: @unchecked Sendable {
    let lock = NSLock()
    var output = Data(), pending = Data()
    var finished = false, overflow = false
    func consume(_ data: Data, input: FileHandle, lineHandler: ((String, FileHandle) -> Bool)?) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard output.count + data.count <= 2_097_152 else { overflow = true; lock.unlock(); return }
        output.append(data); pending.append(data)
        var lines: [String] = []
        while let index = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[..<index], as: UTF8.self))
            pending.removeSubrange(...index)
        }
        lock.unlock()
        for line in lines where lineHandler?(line, input) == true { lock.lock(); finished = true; lock.unlock() }
    }
    func flags() -> (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (finished, overflow) }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: output, as: UTF8.self) }
}
enum CodexCommand {
    static func locate(_ requested: String?) throws -> String {
        var candidates = [String]()
        if let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (requested as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw CodexClientError.missingCLI }
            return path
        }
        candidates += ["/Applications/Codex.app/Contents/Resources/codex",NSHomeDirectory()+"/Applications/Codex.app/Contents/Resources/codex","/opt/homebrew/bin/codex","/usr/local/bin/codex"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0)+"/codex" }
        guard let path = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else { throw CodexClientError.missingCLI }
        return path
    }
    static func run(path: String, arguments: [String], input: Data, timeout: TimeInterval, directory: URL? = nil, lineHandler: ((String, FileHandle) -> Bool)? = nil) async throws -> CodexCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe(), capture = CommandCapture()
                process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
                process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
                process.currentDirectoryURL = directory ?? FileManager.default.temporaryDirectory
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                process.environment = environment
                stdout.fileHandleForReading.readabilityHandler = { handle in capture.consume(handle.availableData, input: stdin.fileHandleForWriting, lineHandler: lineHandler) }
                // Discard diagnostic stderr, which may contain account identifying information.
                stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
                do {
                    try process.run()
                    try stdin.fileHandleForWriting.write(contentsOf: input)
                    if lineHandler == nil { try? stdin.fileHandleForWriting.close() }
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline && !capture.flags().0 && !capture.flags().1 { Thread.sleep(forTimeInterval: 0.05) }
                    let timedOut = process.isRunning && Date() >= deadline
                    if process.isRunning {
                        process.terminate()
                        let grace = Date().addingTimeInterval(0.5)
                        while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    Thread.sleep(forTimeInterval: 0.05)
                    stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
                    try? stdin.fileHandleForWriting.close()
                    if timedOut { throw CodexClientError.timedOut }
                    if capture.flags().1 { throw CodexClientError.tooMuchOutput }
                    continuation.resume(returning: CodexCommandResult(stdout: capture.text(), exitCode: process.terminationStatus))
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
                    if process.isRunning { process.terminate() }
                    try? stdin.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
