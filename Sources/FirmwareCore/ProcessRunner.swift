import Foundation

public enum ProcessEvent: Sendable, Equatable {
    case output(String)
    case exited(Int32)
}

/// Runs a command and streams its combined stdout/stderr lines, then its exit status.
/// `environment` is added to this process's environment.
/// Cancelling the consuming task terminates the process and any children it spawned
/// (ipecmd's shell wrapper runs Java as a child process).
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = ProcessBox()
            let process = box.process
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let (exitStream, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
            process.terminationHandler = { finished in
                exitContinuation.yield(finished.terminationStatus)
                exitContinuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let reader = Task {
                do {
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        continuation.yield(.output(line))
                    }
                } catch {
                    // The pipe closes when the process exits; nothing left to read.
                }
                var status: Int32 = -1
                for await code in exitStream { status = code }
                continuation.yield(.exited(status))
                continuation.finish()
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    box.terminateTree()
                    reader.cancel()
                }
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()

    func terminateTree() {
        guard process.isRunning else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        process.terminate()
    }
}
