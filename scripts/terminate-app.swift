import AppKit
import Darwin

let bundleIdentifier = "app.openglyph.mac"
var arguments = Array(CommandLine.arguments.dropFirst())
let probeOnly = arguments.first == "--probe"
if probeOnly { arguments.removeFirst() }
guard arguments.count == 1, (arguments[0] as NSString).isAbsolutePath else {
    fputs("Usage: swift scripts/terminate-app.swift [--probe] INSTALLED_EXECUTABLE_PATH\n", stderr)
    exit(2)
}

func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

let executablePath = canonicalPath(arguments[0])
let executableURL = URL(fileURLWithPath: executablePath)
guard executableURL.lastPathComponent == "OpenGlyph",
      executableURL.deletingLastPathComponent().lastPathComponent == "MacOS",
      executableURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
      executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "OpenGlyph.app" else {
    fputs("Expected an installed OpenGlyph.app/Contents/MacOS/OpenGlyph executable path.\n", stderr)
    exit(2)
}

struct MatchingProcess: Equatable {
    let pid: pid_t
    let userID: uid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
}

struct ProcessCheckError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Unlike NSWorkspace, these kernel process queries work from an SSH audit session.
// The start time protects against reusing an old PID before requesting termination.
func matchingProcess(_ pid: pid_t) throws -> MatchingProcess? {
    guard pid > 0, pid != getpid() else { return nil }
    var info = proc_bsdinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
        let infoError = errno
        if infoError == ESRCH { return nil }
        throw ProcessCheckError("Cannot inspect current-user PID \(pid), error \(infoError). Refusing to replace the app.")
    }
    guard info.pbi_pid == UInt32(pid), info.pbi_uid == geteuid(), info.pbi_ruid == getuid(),
          info.pbi_status != SZOMB else { return nil }

    // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; Swift cannot import that macro.
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
        proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
    }
    guard pathLength > 0 else {
        let pathError = errno
        if pathError == ESRCH { return nil }
        throw ProcessCheckError("Cannot verify the executable path of current-user PID \(pid), error \(pathError). Refusing to replace the app.")
    }
    guard canonicalPath(String(cString: pathBuffer)) == executablePath else { return nil }
    return MatchingProcess(pid: pid, userID: info.pbi_uid,
                           startedSeconds: info.pbi_start_tvsec,
                           startedMicroseconds: info.pbi_start_tvusec)
}

func matchingProcesses() throws -> [MatchingProcess] {
    let initialBytes = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
    guard initialBytes > 0 else {
        throw ProcessCheckError("Cannot enumerate the current user's processes. Refusing to replace the app.")
    }
    var capacity = Int(initialBytes) / MemoryLayout<pid_t>.stride + 64
    // Leave spare entries for processes created between sizing and enumeration.
    for _ in 0..<4 {
        var pids = [pid_t](repeating: 0, count: capacity)
        let countBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), buffer.baseAddress, Int32(buffer.count))
        }
        guard countBytes > 0 else {
            throw ProcessCheckError("Cannot enumerate the current user's processes. Refusing to replace the app.")
        }
        let count = Int(countBytes) / MemoryLayout<pid_t>.stride
        if count < capacity {
            return try pids.prefix(count).compactMap { try matchingProcess($0) }.sorted { $0.pid < $1.pid }
        }
        capacity *= 2
    }
    throw ProcessCheckError("The process list kept changing. Refusing to replace the app; try the installation again.")
}

do {
    let processes = try matchingProcesses()
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { !$0.isTerminated }
    let visiblePIDs = Set(applications.map(\.processIdentifier))
    if probeOnly {
        let report: [String: Any] = [
            "executablePath": executablePath,
            "matchingProcesses": processes.map { process -> [String: Any] in
                ["pid": process.pid, "uid": process.userID,
                 "startedSeconds": process.startedSeconds, "startedMicroseconds": process.startedMicroseconds,
                 "visibleToNSRunningApplication": visiblePIDs.contains(process.pid)]
            }
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        exit(0)
    }

    for process in processes {
        // Recheck ownership, executable path, and process identity immediately
        // before either termination route. Never signal a cached PID by itself.
        guard try matchingProcess(process.pid) == process else { continue }
        if let application = applications.first(where: { $0.processIdentifier == process.pid }) {
            guard application.terminate() else {
                throw ProcessCheckError("OpenGlyph declined to quit. Quit it from its menu before installing.")
            }
            print("Requested OpenGlyph to quit, PID \(process.pid).")
        } else {
            if Darwin.kill(process.pid, SIGTERM) != 0, errno != ESRCH {
                throw ProcessCheckError("Could not terminate the verified installed OpenGlyph process, PID \(process.pid). Quit it before installing.")
            }
            print("Sent SIGTERM to the verified installed OpenGlyph executable, PID \(process.pid).")
        }
    }

    let deadline = Date().addingTimeInterval(10)
    var remaining = try matchingProcesses()
    while !remaining.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        remaining = try matchingProcesses()
    }
    guard remaining.isEmpty else {
        let pids = remaining.map { String($0.pid) }.joined(separator: ", ")
        throw ProcessCheckError("OpenGlyph is still running at \(executablePath), PIDs \(pids). Refusing to replace the app. Quit it before installing.")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
