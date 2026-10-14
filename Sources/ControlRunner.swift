import Foundation
import Darwin

struct ControlResult: Sendable {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
    let truncated: Bool
}

/// Bounded output capture for short control commands, not for running MCP jobs.
/// No detached reader, unbounded read-to-EOF, or unbounded waitUntilExit is used.
enum ControlRunner {
    static let outputLimit = 64 * 1024

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> ControlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
            return ControlResult(output: "无法创建非阻塞命令输出通道。", exitCode: -1, timedOut: false, truncated: false)
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
            return ControlResult(output: "无法启动控制脚本，请检查应用安装。", exitCode: -1, timedOut: false, truncated: false)
        }
        // The parent must close its own write endpoint, or EOF never arrives.
        pipe.fileHandleForWriting.closeFile()
        defer { pipe.fileHandleForReading.closeFile() }

        var captured = Data()
        captured.reserveCapacity(outputLimit)
        var chunk = [UInt8](repeating: 0, count: 4096)
        var truncated = false
        var eof = false
        var exited = false
        var exitObservedAt: TimeInterval?
        var stopRequestedAt: TimeInterval?
        var timedOut = false
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)

        while true {
            // A noisy child must not starve deadline checks.
            for _ in 0..<64 {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    let remaining = max(0, outputLimit - captured.count)
                    if count > remaining { truncated = true }
                    if remaining > 0 { captured.append(contentsOf: chunk.prefix(min(count, remaining))) }
                } else {
                    if count == 0 { eof = true }
                    break
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if !exited && completed.wait(timeout: .now()) == .success {
                exited = true
                exitObservedAt = now
            }
            if exited && (eof || now - (exitObservedAt ?? now) >= 0.25) { break }
            if !exited && now >= deadline && stopRequestedAt == nil {
                timedOut = true
                stopRequestedAt = now
                if process.isRunning { process.terminate() }
            }
            // No force termination: an unresponsive control command is reported.
            if let stopped = stopRequestedAt, now - stopped >= 1.0 { break }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = Darwin.poll(&event, 1, 50)
            if eof && !exited { Thread.sleep(forTimeInterval: 0.02) }
        }
        let code: Int32 = exited ? process.terminationStatus : -2
        return ControlResult(output: String(decoding: captured, as: UTF8.self), exitCode: code, timedOut: timedOut, truncated: truncated)
    }
}
