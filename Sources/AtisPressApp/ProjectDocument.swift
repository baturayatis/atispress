import Foundation
import ImpositionCore
import PDFEngine
import UniformTypeIdentifiers

extension UTType {
    static let atispress = UTType(exportedAs: "com.atispress.project",conformingTo: .json)
    static var projectFile: UTType { UTType(filenameExtension: "atispress",conformingTo: .json) ?? .atispress }
}

enum ProjectFileError: LocalizedError {
    case unsupportedVersion(Int), invalidSelection, sourceMismatch, sourceOverwrite, missingSource(String)
    var errorDescription: String? {
        switch self {
        case .missingSource(let name): return "Kaynak PDF bulunamadı veya değişmiş: \(name). Lütfen dosyayı yeniden bağlayın."
        case .unsupportedVersion(let version): return "Bu proje sürümü desteklenmiyor: \(version)."
        case .invalidSelection: return "Projenin sayfa seçimi veya sırası geçersiz."
        case .sourceMismatch: return "Seçilen PDF projenin sayfa sayısı veya kesim ölçüleriyle eşleşmiyor. Lütfen özgün PDF’yi seçin."
        case .sourceOverwrite: return "Proje, kaynak PDF’nin üzerine kaydedilemez."
        }
    }
}

struct ProjectSource: Codable, Equatable {
    var path: String
    var bookmark: Data
    var fileName: String
    var fileSize: Int64

    static func securityBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: [.fileSizeKey],relativeTo: nil)
    }
    static func capture(_ url: URL,createBookmark: (URL) throws -> Data = securityBookmark) throws -> ProjectSource {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let bookmark = try createBookmark(url)
        return ProjectSource(path: url.path,bookmark: bookmark,fileName: url.lastPathComponent,fileSize: Int64(size))
    }
    /// A bookmark may follow a moved file. A changed size requires explicit relinking.
    func resolve() -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark,options: [.withSecurityScope,.withoutUI],
                              relativeTo: nil,bookmarkDataIsStale: &stale), matches(url,allowRename: true) { return url }
        let url = URL(fileURLWithPath: path)
        return matches(url,allowRename: false) ? url : nil
    }
    private func matches(_ url: URL,allowRename: Bool) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey]),
              values.isRegularFile == true,Int64(values.fileSize ?? -1) == fileSize else { return false }
        return allowRename || url.lastPathComponent == fileName
    }
}

struct GangSourceReference: Codable, Equatable, Identifiable {
    var id: UUID
    var reference: ProjectSource
    var pageCount: Int
}

/// Stores project intent, not a cached plan; the same planner reconstructs preview/export.
struct ProjectState: Codable, Equatable {
    var projectID: UUID? = nil
    var project: Project
    var source: ProjectSource?
    var order: [Int]
    var included: Set<Int>
    var overlays: PDFRenderOptions
    var sheetPreset: String
    var sheetIndex: Int
    var side: SideKind
    var bookletGutter: Double?
    var repetition: Int? = nil
    var gangSources: [GangSourceReference]? = nil
    var repeatGutter: Double
    var gangGutter: Double? = nil
    var linkedSources: [GangSourceReference]? = nil

    func validateSelection(pageCount: Int) throws {
        guard order.count == pageCount,Set(order) == Set((0..<pageCount).map { $0+1 }),
              Set(order).count == order.count,
              included.isSubset(of: Set(order)),
              project.pages.map(\.number) == order.filter({ included.contains($0) }) else {
            throw ProjectFileError.invalidSelection
        }
    }
}
struct ProjectDocument: Codable, Equatable {
    static let currentVersion = 16
    var version: Int = currentVersion
    var state: ProjectState
    static func decode(_ data: Data) throws -> ProjectDocument {
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self,from: data)
        guard (1...currentVersion).contains(header.version) else { throw ProjectFileError.unsupportedVersion(header.version) }
        var file = try decoder.decode(ProjectDocument.self,from: data)
        if header.version < 12,file.state.project.alignment == nil,var state = file.state.project.autoLayout {
            // Legacy projects retain their press-edge geometry even on a later
            // re-import or production change. Explicit auto/reset opts into centering.
            state.manualFields.insert(.alignment); state.automaticFields.remove(.alignment)
            file.state.project.autoLayout = state
        }
        guard file.state.source != nil || !(file.state.linkedSources ?? file.state.gangSources ?? []).isEmpty || file.state.order.isEmpty else { throw ProjectFileError.invalidSelection }
        let sources = file.state.linkedSources ?? file.state.gangSources ?? []
        guard Set(sources.map(\.id)).count == sources.count,sources.allSatisfy({ $0.pageCount > 0 }),
              (file.state.project.gang?.jobs ?? []).allSatisfy({ job in sources.contains { $0.id==job.sourceID } }) else { throw ProjectFileError.invalidSelection }
        if let id = file.state.project.book?.coverSourceID, !sources.contains(where: { $0.id==id }) { throw ProjectFileError.invalidSelection }
        try file.state.validateSelection(pageCount: file.state.order.count)
        return file
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Owns project-file access until the document is replaced; PDFSource owns PDF access.
final class ProjectFileAccess {
    let url: URL
    private let active: Bool
    init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
    deinit { if active { url.stopAccessingSecurityScopedResource() } }
}
