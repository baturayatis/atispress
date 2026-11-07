import Foundation

struct RecentFile: Identifiable, Equatable {
    let id: String
    let url: URL
    let isAvailable: Bool
}

/// App-wide history, separate from saved project intent. Missing files stay listed.
@MainActor
final class RecentFilesStore {
    private struct Entry: Codable {
        var url: URL
        var bookmark: Data?
        var resolvedURL: URL {
            var stale = false
            if let bookmark,let resolved = try? URL(resolvingBookmarkData: bookmark,
                options: [.withSecurityScope,.withoutUI,.withoutMounting],relativeTo: nil,bookmarkDataIsStale: &stale) {
                return resolved
            }
            return url
        }
    }
    private let defaults: UserDefaults
    private let key = "atispress.recentFiles.v1"
    private var entries: [Entry]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self,from: $0) } ?? []
        entries = Array(entries.prefix(5))
    }
    func record(_ url: URL,bookmark: Data?) {
        guard url.isFileURL,["pdf","atispress"].contains(url.pathExtension.lowercased()) else { return }
        let normalized = url.standardizedFileURL
        entries.removeAll { $0.url.standardizedFileURL == normalized || $0.resolvedURL.standardizedFileURL == normalized }
        entries.insert(Entry(url: normalized,bookmark: bookmark),at: 0)
        entries = Array(entries.prefix(5))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data,forKey: key) }
    }
    func files() -> [RecentFile] {
        entries.map { entry in
            let url = entry.resolvedURL
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            return RecentFile(id: entry.url.absoluteString,url: url,
                isAvailable: regular && FileManager.default.isReadableFile(atPath: url.path))
        }
    }
}
