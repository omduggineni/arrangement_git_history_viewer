import Foundation

struct ProcError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

struct ProcResult {
    /// Exit code, or nil if it timed out or was killed by a signal.
    var status: Int32?
    var stdout: Data
    var stderr: String
    var out: String { String(decoding: stdout, as: UTF8.self) }
    var ok: Bool { status == 0 }
}

/// Run a program to completion. Both pipes are drained on their own threads: a
/// chatty child would otherwise fill the pipe buffer and block forever while
/// we wait for its exit. Throws only if the program can't be launched.
func runProcess(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String]? = nil, input: Data? = nil, timeout: TimeInterval = 120) throws -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let env { p.environment = env }
    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { throw ProcError(message: error.localizedDescription) }

    let group = DispatchGroup()
    var outData = Data(), errData = Data()
    group.enter()
    Thread.detachNewThread { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    Thread.detachNewThread { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    if let input {
        Thread.detachNewThread {
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }
    }
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        p.terminate()
        exited.wait()
    }
    group.wait()
    let status: Int32? = (timedOut || p.terminationReason != .exit) ? nil : p.terminationStatus
    return ProcResult(status: status, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
}
