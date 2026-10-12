// Developer benchmark, compiled alongside Sources/OpenGlyphCore/*.swift as one module.
// Generate fixtures in a separate process, then run the same manifest with each build:
// scripts/benchmark-ocr.sh generate --fixtures-dir /tmp/ocr-fixtures
// scripts/benchmark-ocr.sh run --fixtures-dir /tmp/ocr-fixtures --output /tmp/ocr-results.json
// Recognition latency excludes fixture generation, checksum validation, quality scoring, and idle sampling.
// Worker execution is the default and matches the app's Task.detached(.userInitiated) recognition.
// --execution-context main preserves the original synchronous main-thread comparison mode.
// No app, screen, clipboard, history, or settings interaction. Recognized text is never serialized.
import AppKit
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Fixture: Codable {
    let name: String
    let filename: String
    let width: Int
    let height: Int
    let category: String
    let language: String?
    let expectedKind: String
    let expectedLines: [String]
    let sha256: String
}

private struct Manifest: Codable {
    let version: Int
    let createdAt: String
    let fixtures: [Fixture]
}

private struct NativeSample: Encodable {
    let sampledAt: String
    let elapsedSeconds: Double
    let physicalFootprintBytes: UInt64?
    let residentBytes: UInt64?
    let lifetimePeakPhysicalFootprintBytes: UInt64?
    let mallocBlocksInUse: UInt64
    let mallocInUseBytes: UInt64
    let mallocAllocatedBytes: UInt64
    let nativeUserCpuNanoseconds: Double?
    let nativeSystemCpuNanoseconds: Double?
    let thermalStateRaw: Int
    let memoryPressureRaw: Int32?
    let memoryPressureQueryErrno: Int32?
    let processQueryErrno: Int32?
}

private struct Quality: Encodable {
    let expectedCharacterCount: Int
    let recognizedCharacterCount: Int
    let normalizedCharacterCount: Int
    let normalizedOutputSHA256: String
    let normalizedExactMatch: Bool
    let expectedKindMatch: Bool
    let characterErrorRate: Double?
    let characterEditDistance: Int?
    let expectedTokenCount: Int
    let recognizedTokenCount: Int
    let matchedTokenCount: Int
    let tokenPrecision: Double
    let tokenRecall: Double
    let tokenF1: Double
    let tokenComparisonIgnoresReadingOrder: Bool
}

private struct CaseResult: Encodable {
    let fixture: String
    let category: String
    let width: Int
    let height: Int
    let fixtureSHA256: String
    let mode: String
    let language: String
    let executionContext: String
    let recognitionIsMainThread: Bool
    let startedAt: String
    let latencySeconds: Double
    let completed: Bool
    let usedCompatibilityEngine: Bool?
    let usedFastRecovery: Bool?
    let quality: Quality?
    let before: NativeSample
    let after: NativeSample
    let recognitionUserCpuNanoseconds: Double?
    let recognitionSystemCpuNanoseconds: Double?
    let recognitionNativeCpuPercent: Double?
    let errorDomain: String?
    let errorCode: Int?
}

private struct RunReport: Encodable {
    let schemaVersion = 1
    let label: String
    let pid: Int32
    let startedAt: String
    let recognitionStartedAt: String
    let recognitionFinishedAt: String
    let finishedAt: String
    let manifestSHA256: String
    let completedCount: Int
    let failedCount: Int
    let workloadCount: Int
    let qualityFixtureCount: Int
    let startDelaySeconds: Double
    let requestedIdleSeconds: Double
    let executionContext: String
    let latencyDefinition = "full OCRService.recognize(fileURL:options:) pipeline; worker context also includes Task.detached dispatch and main-actor resumption"
    let latencyExcludes = ["fixture generation", "checksum validation", "quality scoring", "idle sampling"]
    let memoryUnit = "bytes"
    let mallocStatisticsDefinition = "malloc_zone_statistics(nil) aggregates all local malloc zones; allocator in-use and reserved bytes are separate from process physical footprint and RSS"
    let nativeCpuUnit = "nanoseconds"
    let nativeCpuConversion = "rusage_info_v4 Mach ticks multiplied by mach_timebase_info numer/denom"
    let nativeCpuPercentDefinition = "100 * native CPU nanoseconds / recognition wall nanoseconds; may exceed 100 with multiple cores"
    let machTimebaseNumerator: UInt32
    let machTimebaseDenominator: UInt32
    let processAtStart: NativeSample
    let processBeforeRecognition: NativeSample
    let cases: [CaseResult]
    let idleSamples: [NativeSample]
    let processAtEnd: NativeSample
}

private enum ExecutionContext: String {
    case worker, main
}

private struct RecognitionExecution: Sendable {
    let result: Result<RecognitionResult, Error>
    let isMainThread: Bool
}

// Keep the diagnostic in the same synchronous call frame as the Vision pipeline.
private func executeRecognition(fileURL: URL, options: RecognitionOptions) -> RecognitionExecution {
    let isMainThread = Thread.isMainThread
    return RecognitionExecution(
        result: Result { try OCRService.recognize(fileURL: fileURL, options: options) },
        isMainThread: isMainThread
    )
}

private struct Arguments {
    var command: String
    var fixtures: URL
    var output: URL?
    var label = "unlabeled"
    var mode = RecognitionMode.accurate
    var language: String?
    var delay = 0.0
    var idle = 30.0
    var executionContext = ExecutionContext.worker
}

private enum BenchmarkError: Int, Error {
    case invalidArguments = 1
    case imageCreation = 2
    case pngEncoding = 3
    case manifestInvalid = 4
    case checksumMismatch = 5
}

private func utcNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
}

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func seconds(since start: UInt64) -> Double { Double(now() - start) / 1_000_000_000 }
private func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func nativeSample(start: UInt64, timebase: mach_timebase_info_data_t) -> NativeSample {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    let usageErrno: Int32? = result == 0 ? nil : errno
    var mallocStatistics = malloc_statistics_t()
    // A nil zone aggregates every local malloc zone. This does not enumerate addresses or allocation contents.
    malloc_zone_statistics(nil, &mallocStatistics)
    let factor = Double(timebase.numer) / Double(timebase.denom)
    var pressure: Int32 = 0
    var pressureSize = MemoryLayout<Int32>.size
    let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
    let pressureErrno: Int32? = pressureResult == 0 ? nil : errno
    return NativeSample(
        sampledAt: utcNow(), elapsedSeconds: seconds(since: start),
        physicalFootprintBytes: result == 0 ? usage.ri_phys_footprint : nil,
        residentBytes: result == 0 ? usage.ri_resident_size : nil,
        lifetimePeakPhysicalFootprintBytes: result == 0 ? usage.ri_lifetime_max_phys_footprint : nil,
        mallocBlocksInUse: UInt64(mallocStatistics.blocks_in_use),
        mallocInUseBytes: UInt64(mallocStatistics.size_in_use),
        mallocAllocatedBytes: UInt64(mallocStatistics.size_allocated),
        nativeUserCpuNanoseconds: result == 0 ? Double(usage.ri_user_time) * factor : nil,
        nativeSystemCpuNanoseconds: result == 0 ? Double(usage.ri_system_time) * factor : nil,
        thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue,
        memoryPressureRaw: pressureResult == 0 ? pressure : nil,
        memoryPressureQueryErrno: pressureErrno, processQueryErrno: usageErrno
    )
}

private func nativeCpuTicks() -> (user: UInt64, system: UInt64)? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? (usage.ri_user_time, usage.ri_system_time) : nil
}

private func normalized(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func editDistance(_ expected: String, _ observed: String) -> Int {
    let a = Array(expected.unicodeScalars)
    let b = Array(observed.unicodeScalars)
    var previous = Array(0...b.count)
    for (i, character) in a.enumerated() {
        var current = [Int](repeating: 0, count: b.count + 1)
        current[0] = i + 1
        for (j, other) in b.enumerated() {
            current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (character == other ? 0 : 1))
        }
        previous = current
    }
    return previous[b.count]
}

private func quality(result: RecognitionResult, fixture: Fixture) -> Quality {
    let expected = normalized(fixture.expectedLines.joined(separator: "\n"))
    let observed = normalized(result.text)
    // Count repeated tokens, rather than sets: dropping most of a dense grid must reduce recall.
    let expectedTokens = expected.split(separator: " ").map(String.init)
    let observedTokens = observed.split(separator: " ").map(String.init)
    let expectedCounts = expectedTokens.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    let observedCounts = observedTokens.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    let matched = expectedCounts.reduce(0) { $0 + min($1.value, observedCounts[$1.key, default: 0]) }
    let precision = observedTokens.isEmpty ? 0 : Double(matched) / Double(observedTokens.count)
    let recall = expectedTokens.isEmpty ? 0 : Double(matched) / Double(expectedTokens.count)
    let isGrid = fixture.category == "dense_grid"
    let distance = isGrid ? nil : editDistance(expected, observed)
    return Quality(
        expectedCharacterCount: fixture.expectedLines.joined(separator: "\n").count,
        recognizedCharacterCount: result.text.count, normalizedCharacterCount: observed.count,
        normalizedOutputSHA256: checksum(Data(observed.utf8)),
        normalizedExactMatch: expected == observed, expectedKindMatch: fixture.expectedKind == result.kind.rawValue,
        characterErrorRate: distance.map { Double($0) / Double(max(1, expected.unicodeScalars.count)) },
        characterEditDistance: distance, expectedTokenCount: expectedTokens.count, recognizedTokenCount: observedTokens.count,
        matchedTokenCount: matched, tokenPrecision: precision, tokenRecall: recall,
        tokenF1: precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0,
        tokenComparisonIgnoresReadingOrder: true
    )
}

private func bitmap(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw BenchmarkError.imageCreation }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context
}

private func grid(width: Int, height: Int, sample: Int) throws -> (CGImage, [String]) {
    let context = try bitmap(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular), .foregroundColor: NSColor.black
    ]
    let heading: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.black
    ]
    let title = "OpenGlyph synthetic text grid sample \(sample)"
    var expected = [title]
    NSAttributedString(string: title, attributes: heading).draw(at: CGPoint(x: 56, y: height - 64))
    let columns = width / 640
    let columnWidth = CGFloat(width - 112) / CGFloat(columns)
    let rows = (height - 160) / 78
    for row in 0..<rows {
        for column in 0..<columns {
            let x = 56 + CGFloat(column) * columnWidth
            let y = CGFloat(height - 122 - row * 78)
            let title = String(format: "Row %02d column %02d sample %02d.", row + 1, column + 1, sample)
            let sentence = "Clear English words for OCR testing."
            expected += [title, sentence]
            NSAttributedString(string: title, attributes: body).draw(at: CGPoint(x: x, y: y))
            NSAttributedString(string: sentence, attributes: body).draw(at: CGPoint(x: x, y: y - 34))
        }
    }
    guard let image = context.makeImage(), image.width == width, image.height == height else { throw BenchmarkError.imageCreation }
    return (image, expected)
}

private func textImage(lines: [String], size: CGFloat, width: Int, height: Int) throws -> CGImage {
    let context = try bitmap(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.black
    ]
    for (index, line) in lines.enumerated() {
        NSAttributedString(string: line, attributes: attributes)
            .draw(at: CGPoint(x: 40, y: CGFloat(height) - 40 - size * 1.5 - CGFloat(index) * size * 2))
    }
    guard let image = context.makeImage() else { throw BenchmarkError.imageCreation }
    return image
}

private func qrImage(payload: String) throws -> CGImage {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw BenchmarkError.imageCreation }
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage, let code = CIContext().createCGImage(output, from: output.extent) else {
        throw BenchmarkError.imageCreation
    }
    let context = try bitmap(width: 700, height: 700)
    context.interpolationQuality = .none
    context.draw(code, in: CGRect(x: 100, y: 100, width: 500, height: 500))
    guard let image = context.makeImage() else { throw BenchmarkError.imageCreation }
    return image
}

private func writeFixture(
    image: CGImage, lines: [String], filename: String, category: String, language: String?,
    kind: String = "text", directory: URL
) throws -> Fixture {
    let url = directory.appendingPathComponent(filename)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw BenchmarkError.pngEncoding
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BenchmarkError.pngEncoding }
    return Fixture(name: filename, filename: filename, width: image.width, height: image.height,
                   category: category, language: language, expectedKind: kind, expectedLines: lines,
                   sha256: checksum(try Data(contentsOf: url)))
}

private func emit<T: Encodable>(_ value: T, output: URL? = nil) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let output { try data.write(to: output, options: .atomic) }
    print(String(decoding: data, as: UTF8.self))
}

private func generate(_ args: Arguments) throws {
    let manifestURL = args.fixtures.appendingPathComponent("manifest.json")
    // Do not silently regenerate shared fixtures between baseline and candidate runs.
    guard !FileManager.default.fileExists(atPath: manifestURL.path) else { throw BenchmarkError.manifestInvalid }
    try FileManager.default.createDirectory(at: args.fixtures, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var fixtures: [Fixture] = []
    for index in 1...12 {
        let width = index % 2 == 1 ? 1920 : 3840
        let height = index % 2 == 1 ? 1080 : 2160
        fixtures.append(try autoreleasepool {
            let (image, lines) = try grid(width: width, height: height, sample: index)
            return try writeFixture(image: image, lines: lines, filename: String(format: "grid-%02d-%dx%d.png", index, width, height),
                                    category: "dense_grid", language: nil, directory: args.fixtures)
        })
    }
    let textFixtures: [(String, [String], CGFloat, Int, Int, String, String?)] = [
        ("simple-text.png", ["LOCAL TEXT CAPTURE", "SECOND LINE 42"], 48, 1200, 500, "simple_text", "en-US"),
        ("small-font-12.png", ["Small text remains clear at 12 pixels.", "Every readable word matters for accuracy."], 12, 1200, 250, "small_font", "en-US"),
        ("small-font-16.png", ["Small text remains clear at 16 pixels.", "Every readable word matters for accuracy."], 16, 1200, 250, "small_font", "en-US"),
        ("small-font-20.png", ["Small text remains clear at 20 pixels.", "Every readable word matters for accuracy."], 20, 1200, 250, "small_font", "en-US"),
        ("language-german.png", ["Grüße aus Berlin", "Über sieben Brücken gehen wir."], 40, 1200, 400, "language", "de-DE"),
        ("language-french.png", ["Bonjour à tous", "La lumière éclaire notre journée."], 40, 1200, 400, "language", "fr-FR"),
        ("language-spanish.png", ["Buenos días", "El niño tomó café por la mañana."], 40, 1200, 400, "language", "es-ES")
    ]
    for (name, lines, size, width, height, category, language) in textFixtures {
        fixtures.append(try autoreleasepool {
            try writeFixture(image: textImage(lines: lines, size: size, width: width, height: height), lines: lines,
                             filename: name, category: category, language: language, directory: args.fixtures)
        })
    }
    let payload = "https://example.com/openglyph-benchmark"
    fixtures.append(try writeFixture(image: qrImage(payload: payload), lines: [payload], filename: "qr-code.png",
                                    category: "qr_code", language: nil, kind: "qrCode", directory: args.fixtures))
    let manifest = Manifest(version: 1, createdAt: utcNow(), fixtures: fixtures)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    try emit(["generatedFixtureCount": fixtures.count, "denseGridCount": 12, "qualityFixtureCount": fixtures.count - 12])
}

@MainActor
private func runBenchmark(_ args: Arguments) async throws {
    let start = now()
    let startedAt = utcNow()
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let processAtStart = nativeSample(start: start, timebase: timebase)
    let manifestData = try Data(contentsOf: args.fixtures.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    guard manifest.version == 1, manifest.fixtures.count == 20,
          manifest.fixtures.prefix(12).allSatisfy({ $0.category == "dense_grid" }),
          manifest.fixtures.prefix(12).filter({ $0.width == 1920 && $0.height == 1080 }).count == 6,
          manifest.fixtures.prefix(12).filter({ $0.width == 3840 && $0.height == 2160 }).count == 6 else {
        throw BenchmarkError.manifestInvalid
    }
    // Validate identical PNG bytes before the attach delay and before measuring any recognition.
    for fixture in manifest.fixtures {
        guard fixture.filename == URL(fileURLWithPath: fixture.filename).lastPathComponent,
              checksum(try Data(contentsOf: args.fixtures.appendingPathComponent(fixture.filename))) == fixture.sha256 else {
            throw BenchmarkError.checksumMismatch
        }
    }
    if args.delay > 0 { try await Task.sleep(nanoseconds: UInt64(args.delay * 1_000_000_000)) }
    let beforeRecognition = nativeSample(start: start, timebase: timebase)
    let recognitionStartedAt = utcNow()
    var cases: [CaseResult] = []
    for fixture in manifest.fixtures {
        let options = RecognitionOptions(mode: args.mode, language: fixture.language ?? args.language)
        let fileURL = args.fixtures.appendingPathComponent(fixture.filename)
        let before = nativeSample(start: start, timebase: timebase)
        let caseStartedAt = utcNow()
        // Read native counters immediately around the production API, excluding scoring and metadata work.
        let cpuBefore = nativeCpuTicks()
        let recognitionStart = now()
        // An outer benchmark pool would mask production file-decoding autorelease lifetimes.
        let execution: RecognitionExecution
        if args.executionContext == .worker {
            execution = await Task.detached(priority: .userInitiated) {
                executeRecognition(fileURL: fileURL, options: options)
            }.value
        } else {
            execution = executeRecognition(fileURL: fileURL, options: options)
        }
        let outcome = execution.result
        let latency = seconds(since: recognitionStart)
        let cpuAfter = nativeCpuTicks()
        let after = nativeSample(start: start, timebase: timebase)
        let factor = Double(timebase.numer) / Double(timebase.denom)
        let userDelta = cpuBefore.flatMap { old in cpuAfter.map { Double($0.user - old.user) * factor } }
        let systemDelta = cpuBefore.flatMap { old in cpuAfter.map { Double($0.system - old.system) * factor } }
        let cpu = userDelta.flatMap { user in systemDelta.map { 100 * (user + $0) / (latency * 1_000_000_000) } }
        let result: RecognitionResult?
        let failure: NSError?
        switch outcome {
        case .success(let recognized): result = recognized; failure = nil
        case .failure(let error): result = nil; failure = error as NSError
        }
        cases.append(CaseResult(
            fixture: fixture.name, category: fixture.category, width: fixture.width, height: fixture.height,
            fixtureSHA256: fixture.sha256, mode: args.mode.rawValue, language: options.language ?? "auto",
            executionContext: args.executionContext.rawValue, recognitionIsMainThread: execution.isMainThread,
            startedAt: caseStartedAt, latencySeconds: latency, completed: result != nil,
            usedCompatibilityEngine: result?.usedCompatibilityEngine, usedFastRecovery: result?.usedFastRecovery,
            quality: result.map { value in autoreleasepool { quality(result: value, fixture: fixture) } }, before: before, after: after,
            recognitionUserCpuNanoseconds: userDelta, recognitionSystemCpuNanoseconds: systemDelta,
            recognitionNativeCpuPercent: cpu, errorDomain: failure?.domain, errorCode: failure?.code
        ))
    }
    let recognitionFinishedAt = utcNow()
    let idleStart = now()
    var idleSamples = [nativeSample(start: start, timebase: timebase)]
    while seconds(since: idleStart) < args.idle {
        let delay = min(2, max(0, args.idle - seconds(since: idleStart)))
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        idleSamples.append(nativeSample(start: start, timebase: timebase))
    }
    let processAtEnd = nativeSample(start: start, timebase: timebase)
    let report = RunReport(
        label: args.label, pid: getpid(), startedAt: startedAt, recognitionStartedAt: recognitionStartedAt,
        recognitionFinishedAt: recognitionFinishedAt, finishedAt: utcNow(), manifestSHA256: checksum(manifestData),
        completedCount: cases.filter(\.completed).count, failedCount: cases.filter { !$0.completed }.count,
        workloadCount: 12, qualityFixtureCount: manifest.fixtures.count - 12,
        startDelaySeconds: args.delay, requestedIdleSeconds: args.idle,
        executionContext: args.executionContext.rawValue,
        machTimebaseNumerator: timebase.numer, machTimebaseDenominator: timebase.denom,
        processAtStart: processAtStart, processBeforeRecognition: beforeRecognition, cases: cases,
        idleSamples: idleSamples, processAtEnd: processAtEnd
    )
    try emit(report, output: args.output)
}

private func parseArguments() throws -> Arguments {
    let raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first, ["generate", "run"].contains(command), (raw.count - 1) % 2 == 0 else {
        throw BenchmarkError.invalidArguments
    }
    var values: [String: String] = [:]
    let allowed = ["--fixtures-dir", "--output", "--label", "--mode", "--language", "--start-delay-seconds", "--idle-seconds", "--execution-context"]
    for index in stride(from: 1, to: raw.count, by: 2) {
        guard allowed.contains(raw[index]), values[raw[index]] == nil else { throw BenchmarkError.invalidArguments }
        values[raw[index]] = raw[index + 1]
    }
    guard let directory = values["--fixtures-dir"], !directory.isEmpty else { throw BenchmarkError.invalidArguments }
    var args = Arguments(command: command, fixtures: URL(fileURLWithPath: directory, isDirectory: true))
    if let output = values["--output"] { args.output = URL(fileURLWithPath: output) }
    if let label = values["--label"] { args.label = label }
    if let mode = values["--mode"] {
        guard let parsed = RecognitionMode(rawValue: mode) else { throw BenchmarkError.invalidArguments }
        args.mode = parsed
    }
    if let language = values["--language"], language != "auto" { args.language = language }
    if let context = values["--execution-context"] {
        guard let parsed = ExecutionContext(rawValue: context) else { throw BenchmarkError.invalidArguments }
        args.executionContext = parsed
    }
    for (key, value) in [("--start-delay-seconds", 0.0), ("--idle-seconds", 30.0)] {
        let number: Double
        if let rawNumber = values[key] {
            guard let parsed = Double(rawNumber) else { throw BenchmarkError.invalidArguments }
            number = parsed
        } else { number = value }
        guard number.isFinite, number >= 0, number <= 300 else { throw BenchmarkError.invalidArguments }
        if key == "--start-delay-seconds" { args.delay = number } else { args.idle = number }
    }
    return args
}

@main
private enum OCRBenchmark {
    @MainActor
    static func main() async {
        do {
            let args = try parseArguments()
            if args.command == "generate" { try generate(args) } else { try await runBenchmark(args) }
        } catch {
            let native = error as NSError
            struct Failure: Encodable { let errorDomain: String; let errorCode: Int }
            try? emit(Failure(errorDomain: native.domain, errorCode: (error as? BenchmarkError)?.rawValue ?? native.code))
            exit(1)
        }
    }
}
