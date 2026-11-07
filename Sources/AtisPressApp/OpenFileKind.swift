import UniformTypeIdentifiers

enum OpenFileKind {
    case any, pdf, project
    var contentTypes: [UTType] {
        switch self {
        case .any: return [.pdf,.projectFile]
        case .pdf: return [.pdf]
        case .project: return [.projectFile]
        }
    }
    var title: String {
        switch self { case .any: return "Aç"; case .pdf: return "PDF Seç…"; case .project: return "Proje Aç…" }
    }
    var message: String {
        switch self {
        case .any: return "AtışPress projesi (.atispress) veya PDF seçin"
        case .pdf: return "Yüklenecek PDF dosyasını seçin"
        case .project: return "AtışPress projesi (.atispress) seçin"
        }
    }
    func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        switch self {
        case .any: return ["pdf","atispress"].contains(url.pathExtension.lowercased())
        case .pdf: return url.pathExtension.lowercased() == "pdf"
        case .project: return url.pathExtension.lowercased() == "atispress"
        }
    }
}
