import Foundation

/// Looks for `name` on `PATH`, then in the Homebrew bin directories, which
/// aren't on the PATH of apps launched from the Finder.
public func findExecutable(_ name: String) -> URL? {
    let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in pathDirs + ["/opt/homebrew/bin", "/usr/local/bin"] {
        let candidate = URL(filePath: dir).appending(path: name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

public func commandExists(_ cmd: String) -> Bool {
    findExecutable(cmd) != nil
}

/// The output of a finished command.
public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var success: Bool { status == 0 }
}

/// Runs a command to completion, capturing its stdout (stderr is discarded).
/// Throws only if it couldn't be started.
@discardableResult
public func runCapturing(_ executable: URL, _ args: [String]) throws -> CommandOutput {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // Read before waiting, so a full pipe can't block the child.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandOutput(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
}

/// Runs a command to completion with this process's stdin, stdout and stderr,
/// returning its exit status.
@discardableResult
public func runInheriting(_ executable: URL, _ args: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Runs a command to completion with its stdout written to `output` (created
/// or truncated) and stderr discarded, returning its exit status.
@discardableResult
public func runWritingTo(_ output: URL, _ executable: URL, _ args: [String]) throws -> Int32 {
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Replaces this process with `executable`. Only returns (by throwing) if exec fails.
public func execReplacing(_ executable: URL, _ args: [String]) throws -> Never {
    let argv = [executable.path] + args
    var cArgs = argv.map { strdup($0) }
    cArgs.append(nil)
    execv(executable.path, cArgs)
    let err = String(cString: strerror(errno))
    for p in cArgs { free(p) }
    throw CrabError(err)
}

/// The short name of process `pid`, or nil if there's no such process.
func processName(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 256)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    guard n > 0 else {
        // proc_name can fail for other users' processes; check it exists at all.
        return kill(pid, 0) == 0 || errno == EPERM ? "" : nil
    }
    return String(decoding: buf.prefix(Int(n)).map(UInt8.init(bitPattern:)), as: UTF8.self)
}
