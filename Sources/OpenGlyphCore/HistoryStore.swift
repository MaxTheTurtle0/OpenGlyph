import Combine
import Foundation

@MainActor
public final class HistoryStore: ObservableObject {
    public static let maximumEntries = 500
    public static let maximumTextLength = 1_000_000
    @Published public private(set) var items: [CaptureItem] = []
    @Published public private(set) var lastError: String?

    private let directory: URL
    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maximumFileBytes = 32 * 1024 * 1024

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenGlyph", isDirectory: true)
        encoder.outputFormatting = [.sortedKeys]
        load()
    }

    public func add(_ item: CaptureItem) {
        guard item.text.count <= Self.maximumTextLength else {
            lastError = "This capture is too large to save in history."
            return
        }
        let updated = [item] + items.filter { $0.id != item.id }
        save(Array(updated.prefix(Self.maximumEntries)))
    }

    public func remove(_ item: CaptureItem) {
        save(items.filter { $0.id != item.id })
    }

    public func clear() { save([]) }

    public func filtered(query: String, kind: CaptureKind?) -> [CaptureItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (kind == nil || item.kind == kind) &&
            (query.isEmpty || item.text.localizedCaseInsensitiveContains(query) || item.source.localizedCaseInsensitiveContains(query))
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maximumFileBytes else {
                lastError = "The history file exceeds the 32 MB limit."
                return
            }
            let decoded = try decoder.decode([CaptureItem].self, from: Data(contentsOf: historyURL))
            var seen = Set<UUID>()
            items = Array(decoded.filter { $0.text.count <= Self.maximumTextLength && seen.insert($0.id).inserted }
                .prefix(Self.maximumEntries))
        } catch {
            lastError = "Could not read history: \(error.localizedDescription)"
        }
    }

    private func save(_ updated: [CaptureItem]) {
        do {
            let data = try encoder.encode(updated)
            guard data.count <= maximumFileBytes else {
                lastError = "History exceeds 32 MB. Remove older captures before saving this one."
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
            items = updated
            lastError = nil
        } catch {
            lastError = "Could not save history: \(error.localizedDescription)"
        }
    }
}
