import Foundation

/// `claude` CLI binary'sini subprocess olarak calistirir. Kullanici Claude Max
/// abone ya da OAuth login olmus ise API key gerektirmez — CLI kendisi auth'lu.
/// `--output-format json` cikti `result` field'inda raw text doner.
final class ClaudeCLIProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind = .claudeCLI

    private let configuredPath: String

    /// Bos string verilirse standart lokasyonlar (/opt/homebrew/bin/claude, vs.)
    /// taranir. Settings'ten override edilebilir.
    init(configuredPath: String = "") {
        self.configuredPath = configuredPath
    }

    private var binaryURL: URL? {
        if !configuredPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: configuredPath) {
            return URL(fileURLWithPath: configuredPath)
        }
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    func complete(prompt: String, options: AIOptions) async throws -> String {
        guard let bin = binaryURL else {
            AppLogger.bg(.error, .claudeSubprocess, "claude binary bulunamadi",
                         traceId: options.traceId)
            throw AIProviderError.binaryMissing("claude CLI (/opt/homebrew/bin/claude vs.)")
        }
        let proc = Process()
        proc.executableURL = bin
        var args = ["-p", prompt, "--output-format", "json"]
        if !options.tools.isEmpty {
            args.append("--allowedTools")
            args.append(options.tools.joined(separator: ","))
            args.append("--permission-mode")
            args.append("bypassPermissions")
        }
        proc.arguments = args
        proc.currentDirectoryURL = Self.cacheWorkingDir

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        if let nullFH = FileHandle(forReadingAtPath: "/dev/null") {
            proc.standardInput = nullFH
        }

        let outCollector = SubprocessDataCollector()
        let errCollector = SubprocessDataCollector()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if !chunk.isEmpty { Task.detached { await outCollector.append(chunk) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if !chunk.isEmpty { Task.detached { await errCollector.append(chunk) } }
        }

        let startTime = Date()
        let promptPreview = String(prompt.prefix(160))
            .replacingOccurrences(of: "\n", with: " ⏎ ")

        AppLogger.bg(.info, .claudeSubprocess, "subprocess baslatiliyor", [
            "promptSize":  .int(prompt.count),
            "tools":       .string(options.tools.isEmpty ? "(none)" : options.tools.joined(separator: ",")),
            "timeoutSec":  .int(Int(options.timeoutSec)),
            "promptHead":  .string(promptPreview),
        ], traceId: options.traceId)

        try proc.run()
        let pid = proc.processIdentifier

        let timedOut = SubprocessFlag()
        let watchdog = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: UInt64(options.timeoutSec * 1_000_000_000))
            if proc.isRunning {
                await timedOut.set()
                AppLogger.bg(.warn, .claudeSubprocess, "watchdog: timeout — terminate gonderildi", [
                    "pid":        .int(Int(pid)),
                    "timeoutSec": .int(Int(options.timeoutSec)),
                ], traceId: options.traceId)
                proc.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if proc.isRunning {
                    AppLogger.bg(.warn, .claudeSubprocess, "watchdog: SIGKILL",
                                 traceId: options.traceId)
                    kill(pid, SIGKILL)
                }
            }
        }

        proc.waitUntilExit()
        watchdog.cancel()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let tailOut = stdout.fileHandleForReading.availableData
        if !tailOut.isEmpty { await outCollector.append(tailOut) }
        let tailErr = stderr.fileHandleForReading.availableData
        if !tailErr.isEmpty { await errCollector.append(tailErr) }

        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let outData = await outCollector.data
        let errData = await errCollector.data
        let errPreview = String((String(data: errData, encoding: .utf8) ?? "").prefix(240))

        if await timedOut.value {
            AppLogger.bg(.error, .claudeSubprocess, "subprocess timeout", [
                "elapsedMs":   .int(elapsedMs),
                "stdoutBytes": .int(outData.count),
                "stderrHead":  .string(errPreview),
            ], traceId: options.traceId)
            throw AIProviderError.timeout(options.timeoutSec)
        }

        if proc.terminationStatus != 0 {
            AppLogger.bg(.error, .claudeSubprocess, "subprocess non-zero exit", [
                "exitCode":   .int(Int(proc.terminationStatus)),
                "elapsedMs":  .int(elapsedMs),
                "stderrHead": .string(errPreview),
            ], traceId: options.traceId)
            let msg = String(data: errData, encoding: .utf8) ?? "?"
            throw AIProviderError.nonZeroExit(msg)
        }

        var apiDurationMs: Int? = nil
        var numTurns: Int? = nil
        var resultLen: Int = 0
        if let outJSON = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] {
            apiDurationMs = outJSON["duration_api_ms"] as? Int
            numTurns = outJSON["num_turns"] as? Int
            resultLen = (outJSON["result"] as? String)?.count ?? 0
        }

        AppLogger.bg(.info, .claudeSubprocess, "subprocess basarili", [
            "elapsedMs":     .int(elapsedMs),
            "apiDurationMs": .int(apiDurationMs ?? 0),
            "numTurns":      .int(numTurns ?? 0),
            "resultBytes":   .int(resultLen),
            "stdoutBytes":   .int(outData.count),
        ], traceId: options.traceId)

        guard let outJSON = try JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let result = outJSON["result"] as? String, !result.isEmpty else {
            AppLogger.bg(.error, .claudeSubprocess, "result alani yok / bos", [
                "stdoutBytes": .int(outData.count),
            ], traceId: options.traceId)
            throw AIProviderError.emptyResult
        }
        return result
    }

    /// Subprocess working directory pinned away from user folders to avoid
    /// triggering TCC prompts (Photos / Documents / Desktop).
    private static let cacheWorkingDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
