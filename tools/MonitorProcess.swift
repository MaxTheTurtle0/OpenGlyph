// Read-only macOS process monitor. Build: swiftc -O tools/MonitorProcess.swift -o /tmp/MonitorProcess
// Run: MonitorProcess /absolute/executable /new/output/directory durationSeconds intervalSeconds
import Darwin
import Foundation

struct Identity: Hashable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    var key: String { "\(pid):\(seconds):\(microseconds)" }
    var json: [String: Any] { ["pid": pid, "start_unix_seconds": seconds, "start_microseconds": microseconds, "identity": key] }
}

struct Snapshot {
    let time: Double
    let usage: rusage_info_v4
}

struct MonitorError: Error, CustomStringConvertible {
    let description: String
}

let null = NSNull()
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func continuousSeconds() -> Double {
    Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}
func cpuNanoseconds(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
}
func stamp() -> String { formatter.string(from: Date()) }
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
func failure(_ operation: String, _ code: Int32 = errno) -> [String: Any] {
    ["operation": operation, "errno": code, "message": String(cString: strerror(code))]
}
func identity(_ pid: pid_t) -> Identity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_uid == geteuid(), info.pbi_ruid == getuid() else { return nil }
    return Identity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
}
func executable(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}
func usage(_ pid: pid_t) -> (rusage_info_v4?, [String: Any]?) {
    var value = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &value) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? (value, nil) : (nil, failure("proc_pid_rusage"))
}
func neuralMetrics(_ pid: pid_t) -> [String: Any] {
    var value = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &value) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    guard result == 0 else {
        return ["neural_footprint_bytes": null, "lifetime_peak_neural_footprint_bytes": null,
                "neural_query_error": failure("proc_pid_rusage_v6")]
    }
    return ["neural_footprint_bytes": value.ri_neural_footprint,
            "lifetime_peak_neural_footprint_bytes": value.ri_lifetime_max_neural_footprint]
}
func discover(_ path: String) -> ([Identity], [String: Any]?) {
    let bytes = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
    guard bytes > 0 else { return ([], failure("proc_listpids_size")) }
    var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 128)
    let capacity = pids.count * MemoryLayout<pid_t>.size
    let filled = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), &pids, Int32(capacity))
    guard filled > 0, filled < capacity else {
        return ([], ["operation": "proc_listpids", "errno": errno, "message": "Query failed or process list filled the buffer"])
    }
    var result: [Identity] = []
    var pathFailures = 0
    var identityFailures = 0
    for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
        guard let candidatePath = executable(pid) else { pathFailures += 1; continue }
        guard candidatePath == path else { continue }
        guard let candidate = identity(pid) else { identityFailures += 1; continue }
        result.append(candidate)
    }
    let errors: [String: Any]? = pathFailures + identityFailures == 0 ? nil :
        ["path_query_failures": pathFailures, "matching_identity_query_failures": identityFailures,
         "note": "A process may exit during discovery; missing does not prove absence when queries fail"]
    return (result.sorted { $0.pid < $1.pid }, errors)
}
func metrics(_ current: rusage_info_v4, previous: Snapshot?, time: Double) -> [String: Any] {
    var value: [String: Any] = [
        "user_cpu_mach_ticks": current.ri_user_time, "system_cpu_mach_ticks": current.ri_system_time,
        "user_cpu_ns": cpuNanoseconds(current.ri_user_time), "system_cpu_ns": cpuNanoseconds(current.ri_system_time),
        "resident_bytes": current.ri_resident_size, "physical_footprint_bytes": current.ri_phys_footprint,
        "lifetime_peak_physical_footprint_bytes": current.ri_lifetime_max_phys_footprint,
        "pageins_total": current.ri_pageins, "disk_read_bytes_total": current.ri_diskio_bytesread,
        "disk_written_bytes_total": current.ri_diskio_byteswritten,
        "interrupt_wakeups_total": current.ri_interrupt_wkups,
        "package_idle_wakeups_total": current.ri_pkg_idle_wkups,
        "interval_cpu_percent": null, "interval_seconds": null,
        "interval_user_cpu_ns": null, "interval_system_cpu_ns": null,
        "interval_pageins": null, "interval_disk_read_bytes": null, "interval_disk_written_bytes": null,
        "interval_interrupt_wakeups": null, "interval_package_idle_wakeups": null
    ]
    guard let previous else { value["interval_status"] = "first_observation"; return value }
    let elapsed = time - previous.time
    value["interval_seconds"] = elapsed
    let pairs: [(String, UInt64, UInt64)] = [
        ("interval_user_cpu_ns", current.ri_user_time, previous.usage.ri_user_time),
        ("interval_system_cpu_ns", current.ri_system_time, previous.usage.ri_system_time),
        ("interval_pageins", current.ri_pageins, previous.usage.ri_pageins),
        ("interval_disk_read_bytes", current.ri_diskio_bytesread, previous.usage.ri_diskio_bytesread),
        ("interval_disk_written_bytes", current.ri_diskio_byteswritten, previous.usage.ri_diskio_byteswritten),
        ("interval_interrupt_wakeups", current.ri_interrupt_wkups, previous.usage.ri_interrupt_wkups),
        ("interval_package_idle_wakeups", current.ri_pkg_idle_wkups, previous.usage.ri_pkg_idle_wkups)
    ]
    guard elapsed > 0, pairs.allSatisfy({ $0.1 >= $0.2 }) else {
        value["interval_status"] = "counter_reset_or_invalid_time"; return value
    }
    for (name, newer, older) in pairs {
        value[name] = name.contains("cpu_ns") ? cpuNanoseconds(newer - older) as Any : (newer - older) as Any
    }
    value["interval_cpu_percent"] = 100 * (cpuNanoseconds(current.ri_user_time - previous.usage.ri_user_time) +
                                           cpuNanoseconds(current.ri_system_time - previous.usage.ri_system_time)) / elapsed / 1_000_000_000
    value["interval_status"] = "ok"
    return value
}

let host = mach_host_self()
var priorTicks: [UInt32]?
func hostMetrics() -> [String: Any] {
    var result: [String: Any] = ["thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
    var cpu = host_cpu_load_info_data_t()
    var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let cpuStatus = withUnsafeMutablePointer(to: &cpu) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
        }
    }
    result["cpu_busy_percent"] = null
    if cpuStatus == KERN_SUCCESS {
        let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
        if let priorTicks {
            let delta = zip(ticks, priorTicks).map { UInt64($0 &- $1) }
            let total = delta.reduce(0, +)
            if total > 0 { result["cpu_busy_percent"] = 100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) }
        }
        priorTicks = ticks
    } else { result["cpu_query_error"] = cpuStatus; priorTicks = nil }
    var vm = vm_statistics64_data_t()
    var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let vmStatus = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
        }
    }
    if vmStatus == KERN_SUCCESS {
        result["compressor_storage_bytes"] = UInt64(vm.compressor_page_count) * UInt64(vm_page_size)
        result["compressed_original_bytes"] = UInt64(vm.total_uncompressed_pages_in_compressor) * UInt64(vm_page_size)
        result["swapins_pages_total"] = vm.swapins
        result["swapouts_pages_total"] = vm.swapouts
    } else { result["vm_query_error"] = vmStatus }
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
        result["swap_used_bytes"] = swap.xsu_used
        result["swap_total_bytes"] = swap.xsu_total
    } else { result["swap_query_error"] = failure("vm.swapusage") }
    var pressure: Int32 = 0
    var pressureSize = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 {
        result["memory_pressure_level"] = pressure
    } else { result["pressure_query_error"] = failure("kern.memorystatus_vm_pressure_level") }
    return result
}

func encode(_ json: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
}
func run() throws {
    guard CommandLine.arguments.count == 5,
          CommandLine.arguments[1].hasPrefix("/"), CommandLine.arguments[2].hasPrefix("/"),
          let duration = Double(CommandLine.arguments[3]), duration.isFinite, duration > 0, duration <= 86_400,
          let interval = Double(CommandLine.arguments[4]), interval.isFinite, interval >= 0.1, interval <= duration else {
        throw MonitorError(description: "Usage: MonitorProcess /absolute/executable /new/output/directory durationSeconds intervalSeconds")
    }
    let target = canonicalPath(CommandLine.arguments[1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw MonitorError(description: "Output directory already exists; use a new directory")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.appendingPathComponent("samples.jsonl").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw MonitorError(description: "Cannot create samples.jsonl: \(String(cString: strerror(errno)))") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close(); mach_port_deallocate(mach_task_self_, host) }
    let start = continuousSeconds()
    let startDate = stamp()
    let gapThreshold = max(3, 3 * interval)
    let metadata: [String: Any] = [
        "schema_version": 1, "started_at": startDate, "target_executable": target,
        "requested_executable": CommandLine.arguments[1], "target_uid": geteuid(),
        "sampler_pid": getpid(), "duration_seconds": duration, "interval_seconds": interval,
        "mach_timebase_numer": timebase.numer, "mach_timebase_denom": timebase.denom,
        "gap_threshold_seconds": gapThreshold, "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        "full_discovery_interval_seconds": 10,
        "logical_cpu_count": ProcessInfo.processInfo.activeProcessorCount, "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
        "units": ["memory_and_disk": "bytes", "cumulative_cpu": "nanoseconds", "interval_cpu_percent": "one logical core = 100%; can exceed 100%",
                  "host_cpu_busy_percent": "all cores combined, 0...100", "pageins_and_wakeups": "counts",
                  "host_swapins_and_swapouts": "pages", "memory_pressure_level": "kernel bitmask: 1 normal, 2 warning, 4 critical",
                  "thermal_state": "0 nominal, 1 fair, 2 serious, 3 critical"],
        "limitations": ["Lifetime counters and lifetime peak footprint include activity before monitoring started.",
                        "Observed session peaks are maxima of samples, not all allocations between samples.",
                        "CPU deltas across marked gaps include sleep or scheduling delay; do not treat them as awake idle.",
                        "Kernel counters may omit shared OCR helper services, GPU/ANE work, logical/cached I/O, and brief process lifetimes.",
                        "Every exact-path same-user instance is listed separately; a new identity can also be an additional instance.",
                        "Known identities are validated every sample. Full discovery runs every 10 seconds and immediately when a known process disappears; brief additional instances can be missed.",
                        "No text, images, history, process arguments, synthetic activity, or sleep prevention are collected or used."]
    ]
    try encode(metadata).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    var previous: [Identity: Snapshot] = [:]
    var observed: [Identity: [String: Any]] = [:]
    var lastIDs: Set<Identity> = []
    var priorSampler: Snapshot?
    var lastSampleTime: Double?
    var lastDiscoveryTime = -Double.infinity
    var count = 0, missing = 0, queryFailures = 0, gaps = 0, successfulProcessSamples = 0
    var maxResident: UInt64 = 0, maxFootprint: UInt64 = 0
    var next = start
    while continuousSeconds() < start + duration {
        let delay = min(next, start + duration) - continuousSeconds()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard continuousSeconds() < start + duration else { break }
        try autoreleasepool {
            let time = continuousSeconds()
            let sampleGap = lastSampleTime.map { time - $0 }
            let isGap = sampleGap.map { $0 > gapThreshold } ?? false
            if isGap { gaps += 1 }
            let needsDiscovery = time - lastDiscoveryTime >= 10 || lastIDs.isEmpty ||
                lastIDs.contains { identity($0.pid) != $0 || executable($0.pid) != target }
            let ids: [Identity]
            let discoveryError: [String: Any]?
            if needsDiscovery {
                (ids, discoveryError) = discover(target)
                lastDiscoveryTime = time
            } else {
                ids = lastIDs.sorted { $0.pid < $1.pid }
                discoveryError = nil
            }
            let idSet = Set(ids)
            var events: [[String: Any]] = []
            for id in idSet.subtracting(lastIDs) {
                var event = id.json
                event["type"] = observed[id] == nil ? (observed.isEmpty ? "initial_identity" : "new_identity") : "identity_reappeared"
                events.append(event)
            }
            for id in lastIDs.subtracting(idSet) { var event = id.json; event["type"] = "identity_not_observed"; events.append(event) }
            var processes: [[String: Any]] = []
            var current: [Identity: Snapshot] = [:]
            for id in ids {
                var value = id.json
                var instance = observed[id] ?? id.json
                instance["last_observed_at"] = stamp()
                if instance["first_observed_at"] == nil { instance["first_observed_at"] = stamp() }
                observed[id] = instance
                let (resource, error) = usage(id.pid)
                let neural = resource == nil ? [:] : neuralMetrics(id.pid)
                guard let resource, identity(id.pid) == id, executable(id.pid) == target else {
                    value["status"] = "query_failed_or_identity_changed"
                    value["error"] = error ?? ["operation": "identity_recheck", "message": "Process exited, changed identity, or became unreadable"]
                    queryFailures += 1
                    processes.append(value)
                    continue
                }
                let measuredAt = continuousSeconds()
                successfulProcessSamples += 1
                value["status"] = "ok"
                value["metrics"] = metrics(resource, previous: previous[id], time: measuredAt)
                value["neural"] = neural
                var task = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                if proc_pidinfo(id.pid, PROC_PIDTASKINFO, 0, &task, size) == size {
                    value["threads"] = task.pti_threadnum
                } else { value["threads"] = null; value["thread_query_error"] = failure("proc_pidinfo_task") }
                current[id] = Snapshot(time: measuredAt, usage: resource)
                maxResident = max(maxResident, resource.ri_resident_size)
                maxFootprint = max(maxFootprint, resource.ri_phys_footprint)
                processes.append(value)
            }
            if ids.isEmpty { missing += 1 }
            let (selfUsage, selfError) = usage(getpid())
            var sampler: [String: Any] = ["status": selfUsage == nil ? "query_failed" : "ok"]
            if let selfUsage {
                let measuredAt = continuousSeconds()
                sampler["metrics"] = metrics(selfUsage, previous: priorSampler, time: measuredAt)
                priorSampler = Snapshot(time: measuredAt, usage: selfUsage)
            } else { sampler["error"] = selfError; priorSampler = nil }
            var sample: [String: Any] = [
                "timestamp": stamp(), "elapsed_seconds": time - start, "sequence": count,
                "full_discovery_performed": needsDiscovery,
                "sample_gap_seconds": sampleGap as Any? ?? null, "gap_exceeds_threshold": isGap,
                "target_status": ids.isEmpty ? (discoveryError == nil ? "missing" : "missing_with_query_errors") : "present",
                "processes": processes, "identity_events": events, "sampler": sampler, "host": hostMetrics()
            ]
            if let discoveryError { sample["discovery_errors"] = discoveryError }
            var data = try encode(sample)
            data.append(0x0a)
            try file.write(contentsOf: data)
            count += 1
            if count % 30 == 0 { try file.synchronize() }
            previous = current
            lastIDs = idSet
            lastSampleTime = time
        }
        // Skip missed slots rather than manufacturing a burst of catch-up samples.
        next = start + (floor((continuousSeconds() - start) / interval) + 1) * interval
    }
    try file.synchronize()
    let (finalUsage, finalError) = usage(getpid())
    let actualElapsed = continuousSeconds() - start
    let lastElapsed = lastSampleTime.map { $0 - start }
    let unobservedTail = lastElapsed.map { max(0, min(actualElapsed, duration) - $0) }
    var completion: [String: Any] = [
        "schema_version": 1, "status": "completed", "started_at": startDate, "completed_at": stamp(),
        "actual_elapsed_seconds": actualElapsed, "requested_duration_seconds": duration,
        "last_sample_elapsed_seconds": lastElapsed as Any? ?? null,
        "trailing_unobserved_seconds": unobservedTail as Any? ?? null,
        "trailing_gap_exceeds_threshold": unobservedTail.map { $0 > gapThreshold } as Any? ?? null,
        "completion_delay_past_deadline_seconds": max(0, actualElapsed - duration),
        "samples": count, "missing_samples": missing, "target_usage_query_failures": queryFailures,
        "successful_process_samples": successfulProcessSamples,
        "gap_samples": gaps, "observed_identities": observed.values.sorted { ($0["identity"] as! String) < ($1["identity"] as! String) },
        "observed_session_peak_resident_bytes": successfulProcessSamples > 0 ? maxResident as Any : null,
        "observed_session_peak_physical_footprint_bytes": successfulProcessSamples > 0 ? maxFootprint as Any : null
    ]
    if let finalUsage { completion["sampler_final_lifetime_metrics"] = metrics(finalUsage, previous: nil, time: continuousSeconds()) }
    else { completion["sampler_final_query_error"] = finalError }
    try encode(completion).write(to: directory.appendingPathComponent("completion.json"), options: .atomic)
    print(directory.path)
}
do { try run() }
catch {
    FileHandle.standardError.write(Data("MonitorProcess: \(error)\n".utf8))
    exit(1)
}
