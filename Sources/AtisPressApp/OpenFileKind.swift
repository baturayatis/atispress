import Foundation
import UniformTypeIdentifiers
import PDFEngine

enum OpenFileKind {
    case any, pdf, project
    static let artworkTypes: [UTType] = [.pdf] + ImageImport.contentTypes
    var contentTypes: [UTType] {
        switch self {
        case .any: return Self.artworkTypes + [.projectFile]
        case .pdf: return Self.artworkTypes
        case .project: return [.projectFile]
        }
    }
    var title: String {
        switch self { case .any: return "Aç"; case .pdf: return "PDF veya Görsel Seç…"; case .project: return "Proje Aç…" }
    }
    var message: String {
        switch self {
        case .any: return "AtışPress projesi (.atispress) veya PDF/görsel seçin"
        case .pdf: return "Yüklenecek PDF veya görsel dosyasını seçin"
        case .project: return "AtışPress projesi (.atispress) seçin"
        }
    }
    static func droppedURLs(_ providers: [NSItemProvider]) async -> [URL]? {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data {
                        continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                    } else {
                        continuation.resume(returning: item as? URL)
                    }
                }
            }
            guard let url, url.isFileURL else { return nil }
            urls.append(url)
        }
        return urls
    }

    func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        switch self {
        case .any: return OpenFileKind.pdf.accepts(url) || OpenFileKind.project.accepts(url)
        case .pdf: return url.pathExtension.lowercased() == "pdf" || ImageImport.accepts(url)
        case .project: return url.pathExtension.lowercased() == "atispress"
        }
    }
}
