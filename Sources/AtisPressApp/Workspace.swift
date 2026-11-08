import SwiftUI
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

typealias PreviewOverlays = PDFRenderOptions

@MainActor
final class Workspace: ObservableObject {
    static let automaticSheetTitle = "Otomatik (ürüne göre)"
    static func newProject() -> Project {
        var p = Project(pages: [],binding: .stepAndRepeat,
            sheet: SheetSpec(preset: .sra3,margins: Insets(left: 10,right: 10,top: 10,bottom: 10),
                             gripperWidth: 0,gutter: 0))
        p.stepAndRepeat.pageLayout = PageLayoutSettings()
        p.stepAndRepeat.waste = WasteSettings()
        p.sheetInfo = SheetInfoSettings()
        p.exportMarks.colorControls = ColorControlSettings()
        p.autoLayout = AutoLayoutSettings()
        p.autoLayout?.automaticFields.insert(.gutter)
        return p
    }
    @Published var project = Workspace.newProject() {
        didSet {
            if !restoring && !applyingAutomatic && !trackingManual {
                let changed = AutoLayoutField.changes(from: oldValue,to: project)
                if project.binding == .stepAndRepeat && oldValue.binding == .stepAndRepeat {
                    if changed.contains(.gutter) {
                        trackingManual = true; project.stepAndRepeat.arrangement = .custom; trackingManual = false
                    } else if changed.contains(.bleed), project.stepAndRepeat.arrangement == .spaced,
                              project.autoLayout?.manualFields.contains(.gutter) != true {
                        trackingManual = true; project.sheet.gutter = 2*project.settings.bleed; trackingManual = false
                    }
                }
                if !changed.isEmpty {
                    var state = project.autoLayout ?? .legacy
                    if changed.contains(.sheetSize) { state.sheetSelection = .fixed }
                    state.manualFields.formUnion(changed); state.automaticFields.subtract(changed); state.summary = nil
                    trackingManual = true; project.autoLayout = state; trackingManual = false
                }
            }
            if oldValue.stepAndRepeat.quantity != project.stepAndRepeat.quantity { serialInputErrors = [:] }
            if !restoring && !applyingAutomatic && !normalizingDigits { normalizeSerialDigits() }
            refreshModified()
            if applyingAutomatic { return }
            var previous = oldValue
            previous.exportMarks = project.exportMarks
            previous.includeBlankBacks = project.includeBlankBacks
            previous.sheetInfo = project.sheetInfo
            let clipChanged = oldValue.usesFullSheetBooklet != project.usesFullSheetBooklet || previous.autoLayout?.clipBleedToSheet != project.autoLayout?.clipBleedToSheet || previous.autoLayout?.trimTolerance != project.autoLayout?.trimTolerance
            previous.autoLayout = project.autoLayout
            let serialChanged = previous.serialFields != project.serialFields
            previous.serialFields = project.serialFields
            var gangArtworkChanged = false
            if project.binding == .gang,var oldGang = previous.gang,let newGang = project.gang,
               oldGang.jobs.map(\.id) == newGang.jobs.map(\.id) {
                for i in oldGang.jobs.indices {
                    oldGang.jobs[i].serialFields = newGang.jobs[i].serialFields
                    oldGang.jobs[i].name = newGang.jobs[i].name
                    oldGang.jobs[i].tint = newGang.jobs[i].tint
                    oldGang.jobs[i].generatedBleed = newGang.jobs[i].generatedBleed
                }
                gangArtworkChanged = oldGang != previous.gang
                previous.gang = oldGang
            }
            if previous != project || clipChanged || ((serialChanged || gangArtworkChanged) && planning) { schedulePlan() }
            else if serialChanged || gangArtworkChanged {
                plan = ImpositionPlanner.updatingSerials(in: plan,project: project)
                if gangArtworkChanged { warmGeneratedBleed() }
            }
        }
    }
    struct GangAsset { var saved: GangSourceReference; var source: PDFSource }
    @Published private(set) var gangAssets: [GangAsset] = []
    @Published var selectedGangJobID: UUID?
    @Published var selectedGangBlockID: UUID?
    @Published private(set) var source: PDFSource?
    @Published private(set) var plan = ImpositionPlan()
    @Published private(set) var order: [Int] = [] { didSet { refreshModified() } }
    @Published var included = Set<Int>() { didSet { refreshModified() } }
    @Published var selectedPages = Set<Int>()
    @Published var sheetIndex = 0 { didSet {
        if oldValue != sheetIndex { repetition = 0 }
        warmGeneratedBleed()
    } }
    @Published var repetition = 0
    @Published var selectedSerialID: UUID?
    @Published var side: SideKind = .front { didSet { warmGeneratedBleed() } }
    @Published var overlays = PreviewOverlays() { didSet { refreshModified() } }
    @Published var sheetPreset = Workspace.automaticSheetTitle { didSet { refreshModified() } }
    @Published private(set) var isModified = false
    @Published private(set) var projectURL: URL?
    private var sourceReference: ProjectSource?
    private var savedState: ProjectState?
    private var restoring = false
    private var applyingAutomatic = false
    private var trackingManual = false
    private var normalizingDigits = false
    @Published var serialInputErrors: [UUID:String] = [:]
    @Published private(set) var autoArranging = false
    private var autoTask: Task<Void,Never>?
    private var projectAccess: ProjectFileAccess?
    private var savePanel: NSSavePanel?
    var closeApproved = false

    typealias FilePicker = (OpenFileKind,@escaping (URL?) -> Void) -> Void
    private let bookmarkCreator: (URL) throws -> Data
    private let recentStore: RecentFilesStore
    private let filePicker: FilePicker?
    @Published private(set) var recentFiles: [RecentFile] = []
    init(bookmarkCreator: @escaping (URL) throws -> Data = ProjectSource.securityBookmark,
         recentStore: RecentFilesStore? = nil,filePicker: FilePicker? = nil) {
        self.bookmarkCreator = bookmarkCreator
        self.recentStore = recentStore ?? RecentFilesStore()
        self.filePicker = filePicker
        recentFiles = self.recentStore.files()
        savedState = state
    }
    @Published var loading = false
    @Published var planning = false
    @Published var error: String?
    @Published private(set) var samplingBleed = false
    @Published private(set) var bleedSampleSummary: String?
    private var bleedSamplingFailed = false
    private var bleedTask: Task<Void,Never>?
    private var bleedRevision = UUID()
    @Published private(set) var exporting = false
    @Published private(set) var exportSummary: String?
    @Published private(set) var exportedFiles: [URL] = []
    @Published var zoomAction = 0
    @Published var zoomFactor: CGFloat = 1
    private var filePanel: NSOpenPanel?
    private var exportPanel: NSSavePanel?
    private var exportTask: Task<Void,Never>?
    private var planTask: Task<Void,Never>?
    private var importTask: Task<Void,Never>?
    private var bookletGutter: Double?
    private var gangGutter: Double?
    private var repeatGutter: Double = 0
    private var revision = UUID()
    private var importRevision = UUID()

    var displaySheets: [Sheet] { plan.sheets+plan.diagnosticSheets }
    var currentSheet: Sheet? { displaySheets.indices.contains(sheetIndex) ? displaySheets[sheetIndex] : nil }
    var currentSide: Side? { currentSheet.map { side == .front ? $0.front : $0.back } }
    var highlightedSlots: Set<Int> {
        if project.binding == .gang,plan.issues.contains(where: { $0.severity == .error && $0.code == .gangLayout }) { return Set(currentSide?.slots.indices.map { $0 } ?? []) }
        if project.isBooklet && project.book != nil,plan.issues.contains(where:{ $0.severity == .error && $0.code == .bookSettings }) { return Set(currentSide?.slots.indices.map { $0 } ?? []) }
        return Set(plan.issues.compactMap { issue in
            guard let ref = issue.slot, ref.sheet == sheetIndex, ref.side == side else { return nil }
            return ref.slot
        })
    }
    var canExportNow: Bool {
        source != nil && plan.canExport && !plan.sheets.isEmpty && !planning && !loading && !autoArranging && !exporting && !samplingBleed && !bleedSamplingFailed
    }
    private func warmGeneratedBleed() {
        bleedTask?.cancel()
        let token = UUID(); bleedRevision = token
        bleedSamplingFailed = false; bleedSampleSummary = nil
        guard plan.generatedBleed.enabled || currentSheet?.generatedBleedByJob.values.contains(where: { $0.enabled }) == true,let source,let side = currentSide else { samplingBleed = false; return }
        if plan.generatedBleed.method == .solidColor && project.binding != .gang {
            samplingBleed = false
            bleedSampleSummary = plan.generatedBleed.color.components.count == 4 ? "Dolgu: CMYK" : "Dolgu: RGB — özgün CMYK kanalları korunmaz."
            return
        }
        let numbers = Array(Set(side.slots.compactMap(\.sourcePageNumber)))
        if numbers.allSatisfy({ source.edgeSamples.cached(page: $0) != nil }) {
            let native = numbers.filter { source.edgeSamples.cached(page: $0)?.usesCMYK == true }.count
            let rgb = numbers.count-native
            bleedSampleSummary = "Kenar örnekleri: \(native) CMYK · \(rgb) RGB"+(rgb > 0 ? " (özgün CMYK kanalları korunmaz)" : "")
            samplingBleed = false; return
        }
        samplingBleed = true
        bleedTask = Task {
            do {
                try await source.prepareGeneratedBleed(pages: numbers)
                guard !Task.isCancelled,bleedRevision == token else { return }
                let native = numbers.filter { source.edgeSamples.cached(page: $0)?.usesCMYK == true }.count
                let rgb = numbers.count-native
                bleedSampleSummary = "Kenar örnekleri: \(native) CMYK · \(rgb) RGB" + (rgb > 0 ? " (özgün CMYK kanalları korunmaz)" : "")
            } catch {
                guard !Task.isCancelled,bleedRevision == token else { return }
                bleedSamplingFailed = true; self.error = error.localizedDescription
            }
            samplingBleed = false
        }
    }
    private func exportAccessory() -> NSView {
        let view = NSHostingView(rootView: ExportMarksView(model: self))
        view.frame = NSRect(x: 0,y: 0,width: 540,height: 390)
        return view
    }
    func chooseExport(perSheet: Bool) {
        guard canExportNow, let source else { return }
        if let exportPanel { exportPanel.makeKeyAndOrderFront(nil); return }
        if perSheet {
            let panel = NSOpenPanel()
            exportPanel = panel
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.title = "Her tabaka için PDF"; panel.prompt = "Klasörü Seç"
            panel.message = "Yeni bir çıktı klasörü oluşturulacak."
            panel.accessoryView = exportAccessory()
            panel.begin { [weak self] response in
                guard let self else { return }
                self.exportPanel = nil
                guard response == .OK, let folder = panel.url, self.canExportNow else { return }
                let granted = folder.startAccessingSecurityScopedResource()
                let name = source.url.deletingPathExtension().lastPathComponent
                let directory = folder.appendingPathComponent("AtisPress-"+UUID().uuidString,isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
                    self.beginExport(to: .perSheet(directory: directory,baseName: name),
                                     scopedParent: granted ? folder : nil,cleanupOnFailure: directory)
                } catch {
                    if granted { folder.stopAccessingSecurityScopedResource() }
                    self.error = error.localizedDescription
                }
            }
        } else {
            let panel = NSSavePanel()
            exportPanel = panel
            panel.allowedContentTypes = [.pdf]; panel.canCreateDirectories = true
            panel.title = "Bütün işi PDF olarak dışa aktar"; panel.prompt = "Dışa Aktar"
            panel.message = "Çıktı işaretleri önizleme katmanlarından bağımsızdır."
            panel.accessoryView = exportAccessory()
            panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent+"-baski.pdf"
            panel.begin { [weak self] response in
                self?.exportPanel = nil
                if response == .OK, let url = panel.url { self?.beginExport(to: .singlePDF(url)) }
            }
        }
    }
    func cancelExport() { exportTask?.cancel() }
    func revealExport() { NSWorkspace.shared.activateFileViewerSelecting(exportedFiles) }
    func beginExport(to destination: PDFExportDestination,scopedParent: URL? = nil,cleanupOnFailure: URL? = nil) {
        guard canExportNow, let source else {
            if let scopedParent { scopedParent.stopAccessingSecurityScopedResource() }
            if let cleanupOnFailure { try? FileManager.default.removeItem(at: cleanupOnFailure) }
            error = PDFExportError.invalidPlan.localizedDescription; return
        }
        let snapshot = plan, options = project.exportMarks
        let includeBlankBacks = project.includeBlankBacks ?? true
        let sheetInfo = project.sheetInfo ?? SheetInfoSettings(), production = project.autoLayout?.production ?? .digital
        exporting = true; exportSummary = nil; exportedFiles = []
        let worker = Task.detached(priority: .userInitiated) {
            defer { scopedParent?.stopAccessingSecurityScopedResource() }
            do { return try PDFExporter.export(plan: snapshot,source: source,destination: destination,marks: options,jobName: source.url.lastPathComponent,sheetInfo: sheetInfo,production: production,includeBlankBacks: includeBlankBacks) }
            catch {
                if let cleanupOnFailure { try? FileManager.default.removeItem(at: cleanupOnFailure) }
                throw error
            }
        }
        exportTask = Task {
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                exportedFiles = result.files
                exportSummary = "Son çıktı hazır: \(result.sheetCount) tabaka · \(result.pageCount) sayfa · \(result.files.count) dosya" + (result.notes.isEmpty ? "" : " · "+result.notes.joined(separator: " "))
            } catch is CancellationError { exportSummary = "Dışa aktarma iptal edildi." }
            catch { self.error = error.localizedDescription }
            exporting = false
        }
    }
    func setMode(_ mode: BindingMethod) {
        guard mode != project.binding else { return }
        var next = project
        let firstBookletGutter = project.autoLayout?.manualFields.contains(.gutter) == true ? project.sheet.gutter : 6
        if project.binding == .gang { gangGutter = project.sheet.gutter }
        if mode == .stepAndRepeat {
            if project.binding != .gang { bookletGutter = project.sheet.gutter }
            next.sheet.gutter = repeatGutter
        } else if mode == .gang {
            if project.binding == .stepAndRepeat { repeatGutter = project.sheet.gutter }
            else { bookletGutter = project.sheet.gutter }
            next.sheet.gutter = gangGutter ?? 0
        } else if project.binding == .stepAndRepeat {
            repeatGutter = project.sheet.gutter; next.sheet.gutter = bookletGutter ?? firstBookletGutter
        } else if project.binding == .gang { next.sheet.gutter = bookletGutter ?? firstBookletGutter }
        next.binding = mode
        if mode == .gang {
            if next.gang == nil {
                next.gang = GangSettings()
                if let source {
                    let id = UUID()
                    if let reference = sourceReference {
                        gangAssets = [GangAsset(saved: GangSourceReference(id: id,reference: reference,pageCount: source.pages.count),source: source)]
                        sourceReference = nil
                        let jobs = makeGangJobs(source: source,id: id,offset: 0,baseline: next)
                        next.gang?.jobs = jobs
                    }
                }
            }
            selectedGangJobID = next.gang?.jobs.first?.id
        }
        project = next
    }
    // ⌘O, home buttons and the toolbar differ only in their picker filter.
    func openPanel() { chooseFile(.any) }
    func choosePDF() { chooseFile(.pdf) }
    func chooseProject() { chooseFile(.project) }
    private func chooseFile(_ kind: OpenFileKind) {
        guard !loading,!exporting,!autoArranging else { return }
        if let filePanel { filePanel.makeKeyAndOrderFront(nil); return }
        let finish: (URL?) -> Void = { [weak self] url in
            guard let url,kind.accepts(url) else { return }
            self?.open(url)
        }
        if let filePicker { filePicker(kind,finish); return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.allowedContentTypes = kind.contentTypes; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsOtherFileTypes = false
        panel.title = kind.title; panel.prompt = "Aç"; panel.message = kind.message
        panel.begin { [weak self] response in
            self?.filePanel = nil
            finish(response == .OK ? panel.url : nil)
        }
    }
    func open(_ url: URL,confirmChanges: Bool = true) {
        if project.binding == .gang && url.pathExtension.lowercased() == "pdf" { addGangPDFs([url]); return }
        guard !loading, !exporting, !autoArranging, (!confirmChanges || confirmDiscard()) else { return }
        if url.pathExtension.lowercased() == "atispress" {
            loading = true; error = nil
            importTask = Task {
                do { try await loadProject(at: url,relink: chooseRelink) }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
                loading = false
            }
            return
        }
        importTask?.cancel()
        let token = UUID(); importRevision = token
        loading = true; error = nil
        importTask = Task {
            do {
                let source = try await PDFSource.open(url)
                guard !Task.isCancelled, importRevision == token else { return }
                var baseline = project
                var prepared: AutoLayoutResult
                while true {
                    var snapshot = baseline; snapshot.pages = source.pages.map(\.sourcePage); snapshot.gang = nil; snapshot.book?.coverSourceID = nil; snapshot.book?.coverPDFPages = []; snapshot.book?.auxiliaryPages = []; snapshot.book?.selection = CoverSelection()
                    if snapshot.autoLayout == nil { snapshot.autoLayout = .legacy }
                    prepared = await Task.detached(priority: .userInitiated) { SmartAutoLayout.arrange(snapshot) }.value
                    guard !Task.isCancelled,importRevision == token else { return }
                    if prepared.plan.generatedBleed.enabled && prepared.plan.generatedBleed.method != .solidColor {
                        let numbers = Array(Set(prepared.plan.sheets.first?.front.slots.compactMap(\.sourcePageNumber) ?? []))
                        try await source.prepareGeneratedBleed(pages: numbers)
                    }
                    guard !Task.isCancelled,importRevision == token else { return }
                    if baseline == project { break }
                    baseline = project
                }
                guard !Task.isCancelled,importRevision == token else { return }
                planTask?.cancel(); revision = UUID()
                projectURL = nil; projectAccess = nil
                sourceReference = try? ProjectSource.capture(source.url,createBookmark: bookmarkCreator)
                self.source = source
                gangAssets = []
                order = source.pages.map(\.number); included = Set(order); selectedPages = []
                sheetIndex = 0; repetition = 0
                applyAutomatic(prepared)
                loading = false
                recordRecentFile(source.url)
                refreshModified()
            } catch {
                guard !Task.isCancelled, importRevision == token else { return }
                loading = false; self.error = error.localizedDescription
            }
        }
    }
    func setIncluded(_ page: Int, _ value: Bool) {
        if value { included.insert(page) } else { included.remove(page) }
        updateSelection()
    }
    func includeAll(_ value: Bool) {
        included = value ? Set(order) : []; updateSelection()
    }
    private func updateSelection() {
        guard let source else { return }
        project.pages = order.filter { included.contains($0) }.map { source.pages[$0-1].sourcePage }
    }
    func move(_ offsets: IndexSet, to destination: Int) {
        order.move(fromOffsets: offsets,toOffset: destination); updateSelection()
    }
    func moveSelected(up: Bool) {
        guard !selectedPages.isEmpty else { return }
        if up {
            for index in order.indices.dropFirst() where selectedPages.contains(order[index]) && !selectedPages.contains(order[index-1]) {
                order.swapAt(index,index-1)
            }
        } else if order.count > 1 {
            for index in (0..<(order.count-1)).reversed() where selectedPages.contains(order[index]) && !selectedPages.contains(order[index+1]) {
                order.swapAt(index,index+1)
            }
        }
        updateSelection()
    }
    func schedulePlan() {
        planTask?.cancel()
        let token = UUID(); revision = token
        let snapshot = project
        planning = true
        planTask = Task {
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { ImpositionPlanner.plan(snapshot) }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, revision == token else { return }
            plan = next; planning = false
            normalizeSerialDigits()
            sheetIndex = max(0,min(sheetIndex,max(0,displaySheets.count-1)))
            repetition = max(0,min(repetition,(currentSheet?.repeatCount ?? 1)-1))
            warmGeneratedBleed()
        }
    }
    func reveal(_ issue: ValidationIssue) {
        guard let ref = issue.slot else { return }
        sheetIndex = ref.sheet; side = ref.side
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,options: nil) { item,_ in
                        if let data = item as? Data { continuation.resume(returning:URL(dataRepresentation:data,relativeTo:nil)) }
                        else { continuation.resume(returning:item as? URL) }
                    }
                }
                if let url { urls.append(url) }
            }
            if project.binding == .gang,urls.allSatisfy({ $0.pathExtension.lowercased()=="pdf" }) { addGangPDFs(urls) }
            else if let url = urls.first { open(url) }
        }
        return true
    }
}

extension Workspace {
    var state: ProjectState {
        ProjectState(project: project,source: sourceReference,order: order,included: included,
                     overlays: overlays,sheetPreset: sheetPreset,sheetIndex: sheetIndex,side: side,
                     bookletGutter: bookletGutter,repetition: repetition,gangSources: gangAssets.isEmpty || project.book?.coverSourceID != nil ? nil : gangAssets.map(\.saved),repeatGutter: repeatGutter,gangGutter: project.binding == .gang ? project.sheet.gutter : gangGutter,linkedSources: project.book?.coverSourceID == nil ? nil : gangAssets.map(\.saved))
    }
    private func refreshModified() {
        guard !restoring else { return }
        // Navigation is saved but does not make a project dirty by itself.
        var current = state
        current.sheetIndex = savedState?.sheetIndex ?? 0; current.side = savedState?.side ?? .front
        current.repetition = savedState?.repetition
        isModified = current != savedState
    }
    func createNewProject() {
        guard !loading,!exporting,!autoArranging,confirmDiscard() else { return }
        importTask?.cancel(); autoTask?.cancel(); autoArranging = false; planTask?.cancel(); bleedTask?.cancel()
        restoring = true
        gangAssets = []; selectedGangJobID = nil; selectedGangBlockID = nil
        source = nil; sourceReference = nil; projectURL = nil; projectAccess = nil
        order = []; included = []; selectedPages = []; overlays = PreviewOverlays(); sheetPreset = Self.automaticSheetTitle
        bookletGutter = nil; repeatGutter = 0; gangGutter = nil
        project = Self.newProject()
        planTask?.cancel(); revision = UUID()
        plan = ImpositionPlan(); sheetIndex = 0; side = .front; repetition = 0; selectedSerialID = nil
        planning = false; exportSummary = nil; exportedFiles = []; error = nil
        restoring = false; savedState = state; isModified = false
        zoomFactor = 0; zoomAction += 1
    }
    @discardableResult
    func saveProject(as newURL: URL? = nil) throws -> URL {
        guard let url = newURL ?? projectURL else { throw CocoaError(.fileNoSuchFile) }
        if let source, source.protectedURLs.contains(where: { url.standardizedFileURL.resolvingSymlinksInPath() == $0.standardizedFileURL.resolvingSymlinksInPath() }) {
            throw ProjectFileError.sourceOverwrite
        }
        let access = ProjectFileAccess(url)
        var snapshot = state
        if let source,gangAssets.isEmpty { snapshot.source = try ProjectSource.capture(source.url,createBookmark: bookmarkCreator) }
        try snapshot.validateSelection(pageCount: source?.pages.count ?? 0)
        try ProjectDocument(state: snapshot).encoded().write(to: url,options: .atomic)
        sourceReference = snapshot.source; projectURL = url; projectAccess = access
        savedState = snapshot; refreshModified()
        recordRecentFile(url)
        return url
    }
    @discardableResult
    func chooseSave(asNew: Bool = false) -> Bool {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        guard !loading else { return false }
        if !asNew,projectURL != nil {
            do { try saveProject(); return true } catch { self.error = error.localizedDescription; return false }
        }
        guard savePanel == nil else { return false }
        let panel = NSSavePanel(); savePanel = panel
        defer { savePanel = nil }
        panel.title = asNew ? "Farklı Kaydet" : "Kaydet"
        panel.prompt = "Kaydet"; panel.allowedContentTypes = [.projectFile]
        panel.allowsOtherFileTypes = false; panel.canCreateDirectories = true
        panel.nameFieldStringValue = (projectURL?.deletingPathExtension().lastPathComponent ?? source?.url.deletingPathExtension().lastPathComponent ?? "Yeni Proje")+".atispress"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try saveProject(as: url); return true } catch { self.error = error.localizedDescription; return false }
    }
    func confirmDiscard() -> Bool {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Projedeki değişiklikler kaydedilsin mi?"
        alert.informativeText = "Kaydedilmeyen değişiklikler kaybolacak."
        alert.addButton(withTitle: "Kaydet"); alert.addButton(withTitle: "Kaydetme"); alert.addButton(withTitle: "İptal")
        let decision: UnsavedDecision
        switch alert.runModal() {
        case .alertFirstButtonReturn: decision = .save
        case .alertSecondButtonReturn: decision = .discard
        default: decision = .cancel
        }
        return resolveUnsavedChanges(decision,save: { chooseSave() })
    }
    enum UnsavedDecision { case save, discard, cancel }
    func resolveUnsavedChanges(_ decision: UnsavedDecision,save: () -> Bool) -> Bool {
        switch decision {
        case .save: return save()
        case .discard: return true
        case .cancel: return false
        }
    }
    private func chooseRelink(_ reference: ProjectSource) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Kaynak PDF’yi Yeniden Bağla"; panel.prompt = "Yeniden Bağla"
        panel.message = "Kaynak PDF bulunamadı veya değişmiş: \(reference.fileName) (\(reference.fileSize) bayt). Lütfen özgün PDF’yi seçin."
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// Loads into temporary values first: failure/cancel never replaces the active project.
    func loadProject(at url: URL,relink: ((ProjectSource) -> URL?)? = nil) async throws {
        let access = ProjectFileAccess(url)
        let file = try ProjectDocument.decode(Data(contentsOf: url))
        var snapshot = file.state
        var loadedSource: PDFSource?
        var relinked = false
        var assets: [GangAsset] = []
        if let references = snapshot.linkedSources ?? snapshot.gangSources,!references.isEmpty {
            guard Set(references.map(\.id)).count == references.count else { throw ProjectFileError.invalidSelection }
            for saved in references {
                var sourceURL = saved.reference.resolve()
                if sourceURL == nil {
                    guard let relink else { throw ProjectFileError.missingSource(saved.reference.fileName) }
                    guard let replacement = relink(saved.reference) else { throw CancellationError() }
                    sourceURL = replacement; relinked = true
                }
                let loaded = try await PDFSource.open(sourceURL!)
                guard loaded.pages.count == saved.pageCount else { throw ProjectFileError.sourceMismatch }
                let reference = try ProjectSource.capture(sourceURL!,createBookmark: bookmarkCreator)
                assets.append(GangAsset(saved: GangSourceReference(id: saved.id,reference: reference,pageCount: saved.pageCount),source: loaded))
            }
            loadedSource = try await PDFSource.combine(assets.map(\.source),displayName:snapshot.project.book?.coverSourceID == nil ? nil : "Kitap ve kapak")
            try snapshot.validateSelection(pageCount: loadedSource!.pages.count)
            guard snapshot.project.pages.allSatisfy({ loadedSource!.pages[$0.number-1].sourcePage == $0 }) else { throw ProjectFileError.sourceMismatch }
            for job in snapshot.project.gang?.jobs ?? [] {
                guard let assetIndex = assets.firstIndex(where: { $0.saved.id==job.sourceID }) else { throw ProjectFileError.sourceMismatch }
                let start = assets.prefix(assetIndex).reduce(0) { $0+$1.saved.pageCount }
                for page in [job.front,job.back].compactMap({ $0 }) {
                    guard page.number>start,page.number<=start+assets[assetIndex].saved.pageCount,loadedSource!.pages[page.number-1].sourcePage==page else { throw ProjectFileError.sourceMismatch }
                }
            }
            if let book = snapshot.project.book,let id = book.coverSourceID {
                guard let index = assets.firstIndex(where:{ $0.saved.id==id }) else { throw ProjectFileError.sourceMismatch }
                let offset = assets.prefix(index).reduce(0) { $0+$1.saved.pageCount }
                guard book.coverPDFPages.allSatisfy({ $0>offset && $0<=offset+assets[index].saved.pageCount }),
                      book.auxiliaryPages.allSatisfy({ $0>0 && $0<=loadedSource!.pages.count }) else { throw ProjectFileError.sourceMismatch }
            }
            if snapshot.linkedSources != nil { snapshot.linkedSources = assets.map(\.saved) }
            else { snapshot.gangSources = assets.map(\.saved) }
        } else if let reference = snapshot.source {
            var sourceURL = reference.resolve()
            if sourceURL == nil {
                guard let relink else { throw ProjectFileError.missingSource(reference.fileName) }
                guard let replacement = relink(reference) else { throw CancellationError() }
                sourceURL = replacement; relinked = true
            }
            loadedSource = try await PDFSource.open(sourceURL!)
            try snapshot.validateSelection(pageCount: loadedSource!.pages.count)
            let actual = snapshot.project.pages.map { loadedSource!.pages[$0.number-1].sourcePage }
            guard actual == snapshot.project.pages else { throw ProjectFileError.sourceMismatch }
            snapshot.source = try ProjectSource.capture(sourceURL!,createBookmark: bookmarkCreator)
        } else { try snapshot.validateSelection(pageCount: 0) }
        try Task.checkCancellation()
        restoring = true
        planTask?.cancel(); bleedTask?.cancel(); plan = ImpositionPlan()
        gangAssets = assets; selectedGangJobID = snapshot.project.gang?.jobs.first?.id; selectedGangBlockID = nil
        source = loadedSource; sourceReference = snapshot.source
        projectURL = url; projectAccess = access
        order = snapshot.order; included = snapshot.included; selectedPages = []
        bookletGutter = snapshot.bookletGutter; repeatGutter = snapshot.repeatGutter; gangGutter = snapshot.gangGutter
        sheetPreset = snapshot.sheetPreset; project = snapshot.project; overlays = snapshot.overlays
        sheetIndex = snapshot.sheetIndex; side = snapshot.side
        repetition = snapshot.repetition ?? 0; selectedSerialID = nil
        exportSummary = nil; exportedFiles = []; error = nil
        restoring = false
        // Refreshing a valid/stale bookmark alone is not a user edit; relinking is.
        savedState = snapshot; isModified = relinked
        if relinked { savedState?.source = file.state.source; savedState?.gangSources = file.state.gangSources; savedState?.linkedSources = file.state.linkedSources }
        schedulePlan()
        zoomFactor = 0; zoomAction += 1
        recordRecentFile(url)
    }
}

extension Workspace {
    @discardableResult
    func addSerialField() -> UUID {
        let field = SerialField(jobIndex: currentSheet?.repeatLayout?.jobIndex ?? 0)
        editableSerialFields.append(field); selectedSerialID = field.id
        return field.id
    }
    func duplicateSerialField(_ id: UUID) {
        guard var field = editableSerialFields.first(where: { $0.id == id }) else { return }
        field.id = UUID(); field.position.x += 3; field.position.y += 3
        editableSerialFields.append(field); selectedSerialID = field.id
    }
    func moveSerialField(_ id: UUID,to position: Point) {
        guard let index = editableSerialFields.firstIndex(where: { $0.id == id }) else { return }
        editableSerialFields[index].position = Point(position.x.rounded(),position.y.rounded())
    }
}

extension Workspace {
    func autoLabel(_ label: String,_ field: AutoLayoutField) -> String {
        if field == .sheetSize,(project.autoLayout?.sheetSelection ?? .fixed) == .fixed { return label+" · Manuel" }
        if project.autoLayout?.automaticFields.contains(field) == true { return label+" · Otomatik" }
        if project.autoLayout?.manualFields.contains(field) == true { return label+" · Manuel" }
        return label
    }
    func markManual(_ field: AutoLayoutField) {
        guard !restoring,!applyingAutomatic else { return }
        var state = project.autoLayout ?? .legacy
        if field == .sheetSize { state.sheetSelection = .fixed }
        state.manualFields.insert(field); state.automaticFields.remove(field); state.summary = nil
        project.autoLayout = state
        if field == .gutter,project.binding == .stepAndRepeat { project.stepAndRepeat.arrangement = .custom }
        if field == .sheetSize,sheetPreset == Self.automaticSheetTitle { sheetPreset = SmartAutoLayout.presetName(for: project.sheet.size) }
    }
    func autoBinding<T>(_ binding: Binding<T>,_ field: AutoLayoutField) -> Binding<T> {
        Binding(get: { binding.wrappedValue },set: { self.markManual(field); binding.wrappedValue = $0 })
    }
    func setProduction(_ production: ProductionType) {
        var next = project
        var state = project.autoLayout ?? .legacy; state.production = production
        if next.exportMarks.colorControls == nil {
            // These controls did not exist in old projects; an explicit production
            // choice adopts their defaults without treating them as old overrides.
            state.manualFields.subtract([.exportColorBar,.exportTargets])
        }
        if !state.manualFields.contains(.exportColorBar) {
            next.exportMarks.colorBar = production == .offset; state.automaticFields.insert(.exportColorBar)
        }
        if !state.manualFields.contains(.exportTargets) {
            next.exportMarks.registrationTargets = production == .offset; state.automaticFields.insert(.exportTargets)
        }
        next.autoLayout = state
        applyingAutomatic = true; project = next; applyingAutomatic = false
        if overlays.manualColorBar != true { overlays.colorBar = production == .offset }
        if overlays.manualTargets != true { overlays.registrationTargets = production == .offset }
        if !project.pages.isEmpty { autoArrange(resetOverrides: false) }
        else if state.sheetSelection == .automatic {
            applyingAutomatic = true
            project.sheet.size = production == .digital ? SheetPreset.sra3.size : SheetPreset.cm33x48.size
            if !state.manualFields.contains(.gripperWidth) { project.sheet.gripperWidth = production == .digital ? 0 : 10 }
            applyingAutomatic = false
        }
        refreshModified()
    }
    func autoArrange(resetOverrides: Bool = true) {
        guard !loading,!exporting,!autoArranging,!project.pages.isEmpty else { return }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        if project.isBooklet && project.book != nil { schedulePlan(); return }
        if project.binding == .gang { project.gang?.mode = .automatic; project.gang?.blocks = []; schedulePlan(); return }
        let snapshot = project
        autoArranging = true
        autoTask = Task {
            let result = await Task.detached(priority: .userInitiated) { SmartAutoLayout.arrange(snapshot,resetOverrides: resetOverrides) }.value
            guard !Task.isCancelled else { return }
            guard project == snapshot else { autoArranging = false; return }
            if let source,result.plan.generatedBleed.enabled,result.plan.generatedBleed.method != .solidColor {
                do { try await source.prepareGeneratedBleed(pages: Array(Set(result.plan.sheets.first?.front.slots.compactMap(\.sourcePageNumber) ?? []))) }
                catch { self.error = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            guard project == snapshot else { autoArranging = false; return }
            planTask?.cancel(); revision = UUID()
            applyAutomatic(result)
            autoArranging = false
        }
    }
    private func applyAutomatic(_ result: AutoLayoutResult) {
        applyingAutomatic = true
        project = result.project
        if project.autoLayout?.sheetSelection == .automatic { sheetPreset = Self.automaticSheetTitle }
        else if project.autoLayout?.manualFields.contains(.sheetSize) != true { sheetPreset = result.presetName }
        plan = result.plan; planning = false
        sheetIndex = max(0,min(sheetIndex,max(0,displaySheets.count-1)))
        repetition = max(0,min(repetition,(currentSheet?.repeatCount ?? 1)-1))
        applyingAutomatic = false
        normalizeSerialDigits()
        warmGeneratedBleed(); refreshModified()
        zoomFactor = 0; zoomAction += 1
    }
}

extension Workspace {
    func setSheetSelection(_ selection: SheetSelection) {
        var state = project.autoLayout ?? .legacy
        state.sheetSelection = selection
        state.summary = nil
        if selection == .fixed { state.manualFields.insert(.sheetSize); state.automaticFields.remove(.sheetSize) }
        else { state.manualFields.remove(.sheetSize) }
        project.autoLayout = state
        sheetPreset = selection == .automatic ? Self.automaticSheetTitle : SmartAutoLayout.presetName(for: project.sheet.size)
        if !project.pages.isEmpty { autoArrange(resetOverrides: false) }
        else if selection == .automatic {
            applyingAutomatic = true
            project.sheet.size = state.production == .digital ? SheetPreset.sra3.size : SheetPreset.cm33x48.size
            applyingAutomatic = false; refreshModified()
        }
    }
    func returnToAutomaticSheet() { setSheetSelection(.automatic) }
    func serialQuantity(job: Int) -> Int {
        if let job = selectedGangJob { return job.quantity }
        return project.stepAndRepeat.quantity ?? plan.sheets.first(where: { $0.repeatLayout?.jobIndex == job })?.repeatLayout?.copiesPerSheet ?? 1
    }
    func serialNumberedQuantity(job: Int) -> Int {
        if let j = selectedGangJob { return j.waste.numberCopies ? j.waste.quantities(for:j.quantity)?.total ?? j.quantity : j.quantity }
        let quantity = serialQuantity(job: job)
        guard project.stepAndRepeat.waste?.numberCopies == true else { return quantity }
        return project.stepAndRepeat.waste?.quantities(for: quantity)?.total ?? quantity
    }
    func serialSheetCount(job: Int) -> Int {
        if project.binding == .gang { return currentSheet?.repeatCount ?? 0 }
        return plan.sheets.first(where: { $0.repeatLayout?.jobIndex == job })?.repeatCount ?? 0
    }
    func setSerialEnd(_ text: String,id: UUID) {
        guard let field = editableSerialFields.first(where: { $0.id == id }) else { return }
        guard let end = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            serialInputErrors[id] = "Bitiş no geçerli bir 64 bit tam sayı olmalıdır."; return
        }
        do {
            let quantity = try field.quantity(endingAt: end)
            serialInputErrors[id] = nil
            setSerialQuantity(quantity)
        } catch { serialInputErrors[id] = error.localizedDescription }
    }
    func setSerialDigits(_ digits: Int,id: UUID) {
        guard let index = editableSerialFields.firstIndex(where: { $0.id == id }) else { return }
        var fields = editableSerialFields
        fields[index].digits = digits; fields[index].digitsAreManual = true; fields[index].autoIncreasedDigits = nil
        editableSerialFields = fields
    }
    private func normalizeSerialDigits() {
        guard !normalizingDigits else { return }
        if project.binding == .gang, var gang = project.gang {
            for i in gang.jobs.indices {
                let job = gang.jobs[i],quantity = job.waste.numberCopies ? job.waste.quantities(for:job.quantity)?.total ?? job.quantity : job.quantity
                gang.jobs[i].serialFields = job.serialFields.map { $0.adjustedDigits(quantity:quantity) }
            }
            if gang != project.gang { normalizingDigits = true; project.gang = gang; normalizingDigits = false }
            return
        }
        let fields = editableSerialFields.map { $0.adjustedDigits(quantity: serialNumberedQuantity(job: $0.jobIndex)) }
        guard fields != editableSerialFields else { return }
        normalizingDigits = true; editableSerialFields = fields; normalizingDigits = false
    }
}

extension Workspace {
    var repeatArrangement: RepeatArrangement {
        project.stepAndRepeat.arrangement ?? (project.sheet.gutter == 0 ? .adjacent : .custom)
    }
    func setRepeatArrangement(_ arrangement: RepeatArrangement) {
        var next = project
        next.stepAndRepeat.arrangement = arrangement
        var state = next.autoLayout ?? .legacy
        state.summary = nil
        if arrangement == .custom {
            state.manualFields.insert(.gutter); state.automaticFields.remove(.gutter)
        } else {
            state.manualFields.remove(.gutter); state.automaticFields.insert(.gutter)
            next.sheet.gutter = arrangement == .adjacent ? 0 : 2*next.settings.bleed
        }
        next.autoLayout = state
        trackingManual = true; project = next; trackingManual = false
    }
}

extension Workspace {
    func refreshRecentFiles() { recentFiles = recentStore.files() }
    private func recordRecentFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        recentStore.record(url,bookmark: try? bookmarkCreator(url))
        refreshRecentFiles()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    func openRecent(_ file: RecentFile) {
        refreshRecentFiles()
        guard let current = recentFiles.first(where: { $0.id == file.id }),current.isAvailable else { return }
        open(current.url)
    }
}

extension Workspace {
    var pageLayoutMode: PageLayout { project.stepAndRepeat.pageLayout?.mode ?? .duplex }
    var pageLayoutSummary: String {
        let mode = project.resolvedPageLayout == .duplex ? "Çift yüz (1–2 ön/arka, 3–4…)" : "Tek yüz (her sayfa ayrı iş)"
        return mode + (pageLayoutMode == .automatic ? " · Otomatik" : " · Manuel")
    }
    func setPageLayout(_ mode: PageLayout) {
        var next = project
        var settings = next.stepAndRepeat.pageLayout ?? PageLayoutSettings()
        settings.mode = mode; next.stepAndRepeat.pageLayout = settings
        applyPageLayout(next)
    }
    func jobPageLayout(frontPage: Int) -> PageLayout {
        project.stepAndRepeat.pageLayout?.overrides.last(where: { $0.frontPage == frontPage })?.layout ?? .automatic
    }
    func setJobPageLayout(frontPage: Int,mode: PageLayout) {
        var next = project
        var settings = next.stepAndRepeat.pageLayout ?? PageLayoutSettings()
        if next.stepAndRepeat.pageLayout == nil { settings.mode = .duplex }
        settings.overrides.removeAll { $0.frontPage == frontPage }
        if mode != .automatic { settings.overrides.append(PageJobOverride(frontPage: frontPage,layout: mode)) }
        next.stepAndRepeat.pageLayout = settings
        applyPageLayout(next)
    }
    private func applyPageLayout(_ next: Project) {
        var next = next
        let oldJobs = project.repeatJobs,newJobs = next.repeatJobs
        next.serialFields = project.serialFields.flatMap { original -> [SerialField] in
            guard oldJobs.indices.contains(original.jobIndex) else { return [original] }
            let old = oldJobs[original.jobIndex]
            var targets: [(Int,SideKind)] = []
            func attach(_ page: Int,opposite: Bool = false) {
                guard let index = newJobs.firstIndex(where: { $0.front.number == page || $0.back?.number == page }) else { return }
                var side: SideKind = newJobs[index].front.number == page ? .front : .back
                if opposite { side = side == .front ? .back : .front }
                targets.append((index,side))
            }
            if original.sides != .back { attach(old.front.number) }
            if original.sides != .front {
                if let back = old.back { attach(back.number) }
                else { attach(old.front.number,opposite: true) }
            }
            var fields: [SerialField] = []
            for job in Set(targets.map { $0.0 }).sorted() {
                var field = original
                if !fields.isEmpty { field.id = UUID() }
                field.jobIndex = job
                let sides = Set(targets.filter { $0.0 == job }.map { $0.1 })
                field.sides = sides.count == 2 ? .both : sides.contains(.front) ? .front : .back
                fields.append(field)
            }
            return fields.isEmpty ? [original] : fields
        }
        next.autoLayout?.summary = nil
        project = next
    }
    func sheetInfoBinding<T>(_ key: WritableKeyPath<SheetInfoSettings,T>) -> Binding<T> {
        Binding(get: { (self.project.sheetInfo ?? SheetInfoSettings())[keyPath: key] },set: { value in
            var settings = self.project.sheetInfo ?? SheetInfoSettings()
            settings[keyPath: key] = value; self.project.sheetInfo = settings
        })
    }
    var infoJobName: String {
        get { project.sheetInfo?.jobName ?? source?.url.lastPathComponent ?? "İş adı" }
        set { var settings = project.sheetInfo ?? SheetInfoSettings(); settings.jobName = newValue; project.sheetInfo = settings }
    }
    func sheetInfoText(sheet: Sheet,number: Int = 1,kind: SideKind = .front) -> String {
        PDFSheetInfoContext(jobName: sheet.gangJobNames ?? source?.displayName ?? "İş adı",sheetNumber: number,totalSheets: plan.totalPressSheets,
            side: kind,production: project.autoLayout?.production ?? .digital).text(settings: project.sheetInfo ?? SheetInfoSettings(),sheet: sheet)
    }
}

extension Workspace {
    func setPreviewColorBar(_ value: Bool) { overlays.colorBar = value; overlays.manualColorBar = true }
    func setPreviewTargets(_ value: Bool) { overlays.registrationTargets = value; overlays.manualTargets = true }
    var previewControlSettings: ExportMarks {
        var marks = project.exportMarks
        marks.colorBar = overlays.colorBar; marks.registrationTargets = overlays.registrationTargets
        return marks
    }
    var previewControlWarnings: [String] {
        guard let sheet = currentSheet else { return [] }
        return PDFColorControlRenderer.geometry(sheet: sheet,settings: previewControlSettings,kind: side).warnings
    }
}

extension Workspace {
    var serialCodeWarnings: [String] { PDFSerialCodeValidation.warnings(plan: plan) }
}

extension Workspace {
    var selectedGangJob: GangJob? {
        guard project.binding == .gang else { return nil }
        return project.gang?.jobs.first { $0.id==selectedGangJobID } ?? project.gang?.jobs.first
    }
    var editableSerialFields: [SerialField] {
        get { selectedGangJob?.serialFields ?? project.serialFields }
        set {
            if let id = selectedGangJob?.id,let i = project.gang?.jobs.firstIndex(where: { $0.id==id }) { project.gang?.jobs[i].serialFields = newValue }
            else { project.serialFields = newValue }
        }
    }
    func selectSerial(_ id: UUID) {
        if project.binding == .gang,let job = project.gang?.jobs.first(where: { $0.serialFields.contains { $0.id==id } }) { selectedGangJobID = job.id }
        selectedSerialID = id
    }
    func setSerialQuantity(_ quantity: Int) {
        if let id = selectedGangJob?.id { editGangJob(id) { $0.quantity = quantity } }
        else { project.stepAndRepeat.quantity = quantity }
    }
    func editGangJob(_ id: UUID,_ edit: (inout GangJob) -> Void) {
        guard var next = project.gang,let i = next.jobs.firstIndex(where: { $0.id==id }) else { return }
        edit(&next.jobs[i]); project.gang = next
    }
    private func makeGangJobs(source: PDFSource,id: UUID,offset: Int,baseline: Project) -> [GangJob] {
        var single = baseline; single.pages = source.pages.map(\.sourcePage)
        return single.repeatJobs.enumerated().map { index,pair in
            var f = pair.front; f.number += offset
            var b = pair.back; b?.number += offset
            var job = GangJob(sourceID:id,name: source.url.deletingPathExtension().lastPathComponent+" · \(index+1)",front:f,back:b)
            job.quantity = baseline.stepAndRepeat.quantity ?? 1000
            job.waste = baseline.stepAndRepeat.waste ?? WasteSettings()
            job.bleed = baseline.settings.bleed; job.generatedBleed = baseline.settings.generatedBleed
            job.tint = (Double(index+(baseline.gang?.jobs.count ?? 0))*0.61803398875+0.12).truncatingRemainder(dividingBy:1)
            job.serialFields = baseline.serialFields.filter { $0.jobIndex==index }.map { var field = $0; field.id = UUID(); field.jobIndex = 0; return field }
            return job
        }
    }
    func chooseGangPDFs() {
        guard !loading,!exporting else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.title = "Karışık işe PDF ekle"; panel.prompt = "Ekle"
        panel.begin { [weak self] response in if response == .OK { self?.addGangPDFs(panel.urls) } }
    }
    func addGangPDFs(_ urls: [URL]) {
        guard !loading,!exporting,project.binding == .gang,!urls.isEmpty else { return }
        loading = true; error = nil
        importTask = Task {
            do {
                var assets = gangAssets,settings = project.gang ?? GangSettings()
                let originalCount = settings.jobs.count
                for url in urls {
                    let pdf = try await PDFSource.open(url),id = UUID()
                    let reference = try ProjectSource.capture(url,createBookmark: bookmarkCreator)
                    let offset = assets.reduce(0) { $0+$1.source.pages.count }
                    var added = makeGangJobs(source:pdf,id:id,offset:offset,baseline:project)
                    for i in added.indices { added[i].tint = (Double(settings.jobs.count+i)*0.61803398875+0.12).truncatingRemainder(dividingBy:1) }
                    guard settings.jobs.count+added.count<=8 else { throw NSError(domain:"AtisPress",code:1,userInfo:[NSLocalizedDescriptionKey:"Karışık düzende en fazla 8 iş eklenebilir. PDF sayfa çiftlerini ayrı projelere bölün."]) }
                    settings.jobs += added
                    assets.append(GangAsset(saved:GangSourceReference(id:id,reference:reference,pageCount:pdf.pages.count),source:pdf))
                }
                let merged = try await PDFSource.combine(assets.map(\.source))
                try Task.checkCancellation()
                guard project.binding == .gang else { throw CancellationError() }
                let additions = Array(settings.jobs.dropFirst(originalCount))
                settings = project.gang ?? GangSettings(); settings.jobs += additions
                gangAssets = assets; source = merged; sourceReference = nil
                var next = project; next.pages = merged.pages.map(\.sourcePage); next.gang = settings
                order = merged.pages.map(\.number); included = Set(order); selectedPages = []
                project = next; selectedGangJobID = settings.jobs.last?.id
                recordRecentFile(urls.last!); schedulePlan()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    func manualGang() {
        guard let layout = currentSheet?.gangLayout else { return }
        var settings = project.gang ?? GangSettings(); settings.mode = .manual; settings.blocks = layout.blocks
        // Freeze the selected sheet orientation so a drag cannot change its coordinate frame.
        project.sheet.size = currentSheet!.size; project.sheet.orientation = currentSheet!.size.width>currentSheet!.size.height ? .landscape : .portrait
        project.gang = settings; selectedGangBlockID = settings.blocks.first?.id
    }
    func moveGangBlock(_ id: UUID,to origin: Point) {
        if project.gang?.mode != .manual { manualGang() }
        guard let i = project.gang?.blocks.firstIndex(where: { $0.id==id }) else { return }
        project.gang?.blocks[i].origin = Point(origin.x.rounded(),origin.y.rounded()); selectedGangBlockID = id
        selectedGangJobID = project.gang?.blocks[i].jobID
    }
    func removeGangJob(_ id: UUID) {
        project.gang?.jobs.removeAll { $0.id==id }; project.gang?.blocks.removeAll { $0.jobID==id }
        selectedGangJobID = project.gang?.jobs.first?.id; selectedGangBlockID = project.gang?.blocks.first?.id; selectedSerialID = nil
    }
}

extension Workspace {
    var editableGeneratedBleed: GeneratedBleedSettings {
        get { selectedGangJob?.generatedBleed ?? project.settings.generatedBleed }
        set { if let id = selectedGangJob?.id { editGangJob(id) { $0.generatedBleed = newValue } } else { project.settings.generatedBleed = newValue } }
    }
    func gangSourcePages(_ id: UUID) -> [SourcePage] {
        guard let i = gangAssets.firstIndex(where: { $0.saved.id==id }) else { return [] }
        let offset = gangAssets.prefix(i).reduce(0) { $0+$1.saved.pageCount }
        return gangAssets[i].source.pages.map { page in var p = page.sourcePage; p.number += offset; return p }
    }
}

extension Workspace {
    var bookSettings: BookSettings {
        get { project.book ?? BookSettings() }
        set { project.book = newValue }
    }
    func enableBookSettings() { project.book = BookSettings() }
    var bookCoverDomain: [SourcePage] { project.bookCoverPages }
    func coverPageLabel(_ number: Int) -> String {
        var offset = 0
        for asset in gangAssets {
            if number>offset && number<=offset+asset.saved.pageCount { return "\(number-offset) · \(asset.saved.reference.fileName)" }
            offset += asset.saved.pageCount
        }
        return "\(number)"
    }
    func chooseCoverPDF() {
        guard source != nil,!loading,!exporting,project.isBooklet else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        panel.title = "Ayrı kapak PDF’sini seçin"; panel.prompt = "Kapak yükle"
        panel.begin { [weak self] response in if response == .OK,let url = panel.url { self?.loadCoverPDF(url) } }
    }
    func loadCoverPDF(_ url: URL) {
        guard let current = source,!loading,!exporting,project.isBooklet else { return }
        loading = true; error = nil
        importTask = Task {
            do {
                let cover = try await PDFSource.open(url)
                var assets = gangAssets
                if assets.isEmpty {
                    let reference = try ProjectSource.capture(current.url,createBookmark:bookmarkCreator)
                    assets = [GangAsset(saved:GangSourceReference(id:UUID(),reference:reference,pageCount:current.pages.count),source:current)]
                }
                let offset = assets.reduce(0) { $0+$1.saved.pageCount },id = UUID()
                let reference = try ProjectSource.capture(url,createBookmark:bookmarkCreator)
                assets.append(GangAsset(saved:GangSourceReference(id:id,reference:reference,pageCount:cover.pages.count),source:cover))
                let combined = try await PDFSource.combine(assets.map(\.source),displayName:"Kitap ve kapak")
                try Task.checkCancellation()
                guard project.isBooklet else { throw CancellationError() }
                var next = project,book = next.book ?? BookSettings()
                book.coverSourceID = id; book.coverPDFPages = cover.pages.map { $0.number+offset }
                book.auxiliaryPages = Array(Set(book.auxiliaryPages+book.coverPDFPages)).sorted()
                book.selection = CoverSelection()
                next.book = book; next.coverMode = .separate
                let selected = included.union(book.coverPDFPages)
                let newOrder = order+book.coverPDFPages
                next.pages = newOrder.filter { selected.contains($0) }.map { combined.pages[$0-1].sourcePage }
                gangAssets = assets; source = combined; sourceReference = nil
                order = newOrder; included = selected; selectedPages = []
                project = next; sheetIndex = 0; repetition = 0; schedulePlan(); recordRecentFile(url)
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

extension Workspace {
    func showBookSection(_ section: BookSheetInfo.Section) {
        if let index = displaySheets.firstIndex(where:{ $0.bookInfo?.section == section }) { sheetIndex = index }
    }
}
