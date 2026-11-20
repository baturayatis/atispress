import Foundation
import ImpositionCore
import PDFEngine

struct JobTemplate: Codable, Identifiable {
    var id = UUID()
    var name: String
    var expectedSize: Size?
    var settings: Project
    var overlays: PDFRenderOptions

    init(name: String, project: Project, overlays: PDFRenderOptions, expectedSize: Size? = nil) {
        self.name = name
        self.expectedSize = expectedSize
        self.overlays = overlays
        // Keep the layout settings independent of the original PDF and bookmarks.
        var settings = project
        settings.pages = []
        settings.pageItems = nil
        settings.pageItemNextID = nil
        settings.sourcePreparation = nil
        settings.previouslyHadBacks = nil
        settings.book?.coverSourceID = nil
        settings.book?.coverPDFPages = []
        settings.book?.auxiliaryPages = []
        settings.book?.selection = CoverSelection()
        if var gang = settings.gang {
            for index in gang.jobs.indices {
                let job = gang.jobs[index]
                gang.jobs[index].name = ""
                gang.jobs[index].sourceID = job.id
                gang.jobs[index].front = SourcePage(number: 1, trimSize: Size(0, 0))
                gang.jobs[index].back = nil
                gang.jobs[index].splitProduct = nil
            }
            settings.gang = gang
        }
        self.settings = settings
    }

    static func inferredSize(from pages: [SourcePage]) -> Size? {
        guard let first = pages.first?.trimSize, pages.allSatisfy({ matches($0.trimSize, first) }) else { return nil }
        return first
    }

    func mismatch(in pages: [SourcePage]) -> JobTemplateSizeMismatch? {
        guard let expectedSize, let page = pages.first(where: { !Self.matches($0.trimSize, expectedSize) }) else { return nil }
        return JobTemplateSizeMismatch(templateName: name, expected: expectedSize, actual: page.trimSize, page: page.number)
    }

    private static func matches(_ first: Size, _ second: Size) -> Bool {
        let a = [first.width, first.height].sorted()
        let b = [second.width, second.height].sorted()
        return abs(a[0]-b[0]) <= 0.1 && abs(a[1]-b[1]) <= 0.1
    }

    func validated() throws -> Self {
        var template = self
        template.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.name.isEmpty,
              expectedSize.map({ [$0.width, $0.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 10_000 } }) ?? true else {
            throw JobTemplateError.invalidMetadata
        }
        return template
    }

    func applying(to project: Project) -> Project {
        var next = settings
        next.pages = project.pages
        next.pageItems = project.pageItems
        next.pageItemNextID = project.pageItemNextID
        next.sourcePreparation = project.sourcePreparation
        next.previouslyHadBacks = project.previouslyHadBacks
        if let book = project.book {
            next.book?.coverSourceID = book.coverSourceID
            next.book?.coverPDFPages = book.coverPDFPages
            next.book?.auxiliaryPages = book.auxiliaryPages
            next.book?.selection = book.selection
        }
        next.gang = project.gang
        next.team = project.team == nil ? nil : settings.team
        if let gang = settings.gang, var target = next.gang {
            // Job positions connect the saved layout to the current artwork.
            var ids: [UUID: UUID] = [:]
            for index in target.jobs.indices {
                guard gang.jobs.indices.contains(index) else { break }
                let artwork = target.jobs[index]
                var job = gang.jobs[index]
                ids[job.id] = artwork.id
                job.id = artwork.id
                job.name = artwork.name
                job.sourceID = artwork.sourceID
                job.front = artwork.front
                job.back = artwork.back
                job.splitProduct = artwork.splitProduct
                target.jobs[index] = job
            }
            func mapped(_ blocks: [GangBlock]) -> [GangBlock] {
                blocks.compactMap { block in
                    guard let id = ids[block.jobID] else { return nil }
                    var next = block
                    next.jobID = id
                    return next
                }
            }
            let sameJobCount = target.jobs.count == gang.jobs.count
            target.mode = sameJobCount ? gang.mode : .automatic
            target.blocks = sameJobCount ? mapped(gang.blocks) : []
            next.team?.manualLayouts = sameJobCount ? settings.team?.manualLayouts?.map(mapped) : nil
            if var scaling = next.scaling {
                scaling.overrides = scaling.overrides.compactMap { override in
                    guard let id = override.gangID else { return override }
                    guard let mappedID = ids[id] else { return nil }
                    var next = override
                    next.gangID = mappedID
                    return next
                }
                next.scaling = scaling
            }
            next.gang = target
        }
        return next
    }
}

struct JobTemplateSizeMismatch {
    var templateName: String
    var expected: Size
    var actual: Size
    var page: Int
}

enum JobTemplateError: LocalizedError {
    case invalidMetadata, invalidJSON, missingTemplate

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: "Şablon adı ve beklenen iş ebadı geçerli olmalı. Ebat için iki ölçüyü de girin veya ikisini de boş bırakın."
        case .invalidJSON: "Dosya geçerli bir AtışPress iş şablonu içermiyor."
        case .missingTemplate: "İş şablonu bulunamadı."
        }
    }
}

struct JobTemplateStore {
    var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AtışPress/templates", isDirectory: true)

    func load() throws -> [JobTemplate] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { url in
                let template = try Self.read(url)
                guard self.url(template.id).lastPathComponent == url.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                return template
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ template: JobTemplate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write(template, to: url(template.id))
    }

    static func read(_ url: URL) throws -> JobTemplate {
        let data = try Data(contentsOf: url)
        guard let template = try? JSONDecoder().decode(JobTemplate.self, from: data) else {
            throw JobTemplateError.invalidJSON
        }
        return try template.validated()
    }

    static func write(_ template: JobTemplate, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template.validated()).write(to: url, options: .atomic)
    }

    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: url(id)) }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
