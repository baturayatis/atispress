import ColorSync
import CryptoKit
import Foundation

public struct PDFCMYKProfileOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

/// Persist a fingerprint, never a machine-specific path or an assumed profile.
public enum PDFCMYKProfiles {
    public static func installed() -> [PDFCMYKProfileOption] {
        var options: [String: PDFCMYKProfileOption] = [:]
        visitInstalled { url, name in
            guard let data = read(url) else { return }
            let id = fingerprint(data)
            guard options[id] == nil, PDFCMYKImageColor.canAdjust(profile: data) else { return }
            options[id] = PDFCMYKProfileOption(id: id, name: name)
        }
        return options.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(_ id: String) -> Data? {
        guard id.utf8.count == 64 else { return nil }
        var match: Data?
        visitInstalled { url, _ in
            guard match == nil, let data = read(url), fingerprint(data) == id,
                  PDFCMYKImageColor.canAdjust(profile: data) else { return }
            match = data
        }
        return match
    }

    private static func read(_ url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd(), (128...4 * 1024 * 1024).contains(length),
              (try? file.seek(toOffset: 0)) != nil,
              let data = try? file.read(upToCount: Int(length)), data.count == length else { return nil }
        return data
    }

    private final class Visitor {
        let visit: (URL, String) -> Void
        init(_ visit: @escaping (URL, String) -> Void) { self.visit = visit }
    }

    private static func visitInstalled(_ visit: @escaping (URL, String) -> Void) {
        var visited = Set<URL>()
        let visitor = Visitor { url, name in
            guard visited.insert(url.resolvingSymlinksInPath()).inserted else { return }
            visit(url, name)
        }
        let options = [kColorSyncWaitForCacheReply.takeUnretainedValue() as String: true] as CFDictionary
        withExtendedLifetime(visitor) {
            ColorSyncIterateInstalledProfilesWithOptions({ dictionary, context in
                guard !Task.isCancelled else { return false }
                guard let dictionary, let context else { return true }
                let info = dictionary as NSDictionary
                guard let url = info[kColorSyncProfileURL.takeUnretainedValue()] as? URL,
                      let header = info[kColorSyncProfileHeader.takeUnretainedValue()] as? Data,
                      header.count >= 20, String(decoding: header[12..<20], as: UTF8.self) == "prtrCMYK" else { return true }
                let name = info[kColorSyncProfileDescription.takeUnretainedValue()] as? String ?? url.deletingPathExtension().lastPathComponent
                Unmanaged<Visitor>.fromOpaque(context).takeUnretainedValue().visit(url, name)
                return true
            }, nil, Unmanaged.passUnretained(visitor).toOpaque(), options, nil)
        }
        // The ColorSync cache may still be warming at first access.
        let manager = FileManager.default
        let roots = manager.urls(for: .libraryDirectory, in: [.systemDomainMask, .localDomainMask, .userDomainMask])
        for library in roots {
            let folder = library.appendingPathComponent("ColorSync/Profiles", isDirectory: true)
            guard let files = manager.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files {
                guard !Task.isCancelled else { return }
                guard ["icc", "icm"].contains(url.pathExtension.lowercased()) else { continue }
                visitor.visit(url, url.deletingPathExtension().lastPathComponent)
            }
        }
    }
}
