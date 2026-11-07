import SwiftUI
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

typealias PreviewOverlays = PDFRenderOptions

@MainActor
final class Workspace: ObservableObject {
    static func newProject() -> Project {
        var p = Project(pages: [],binding: .stepAndRepeat,
            sheet: SheetSpec(preset: .cm33x48,margins: Insets(left: 10,right: 10,top: 10,bottom: 10),
                             gripperWidth: 10,gutter: 0))
        p.autoLayout = AutoLayoutSettings()
        return p
    }
    @Published var project = Workspace.newProject() {
        didSet {
            if !restoring && !applyingAutomatic && !trackingManual {
                let changed = AutoLayoutField.changes(from: oldValue,to: project)
                if !changed.isEmpty {
                    var state = project.autoLayout ?? .legacy
                    state.manualFields.formUnion(changed); state.automaticFields.subtract(changed); state.summary = nil
                    trackingManual = true; project.autoLayout = state; trackingManual = false
                }
            }
            refreshModified()
            if applyingAutomatic { return }
            var previous = oldValue
            previous.exportMarks = project.exportMarks
            let clipChanged = previous.autoLayout?.clipBleedToSheet != project.autoLayout?.clipBleedToSheet || previous.autoLayout?.trimTolerance != project.autoLayout?.trimTolerance
            previous.autoLayout = project.autoLayout
            let serialChanged = previous.serialFields != project.serialFields
            previous.serialFields = project.serialFields
            if previous != project || clipChanged || (serialChanged && planning) { schedulePlan() }
            else if serialChanged { plan = ImpositionPlanner.updatingSerials(in: plan,project: project) }
        }
    }
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
    @Published var sheetPreset = "33×48" { didSet { refreshModified() } }
    @Published private(set) var isModified = false
    @Published private(set) var projectURL: URL?
    private var sourceReference: ProjectSource?
    private var savedState: ProjectState?
    private var restoring = false
    private var applyingAutomatic = false
    private var trackingManual = false
    @Published private(set) var autoArranging = false
    private var autoTask: Task<Void,Never>?
    private var projectAccess: ProjectFileAccess?
    private var savePanel: NSSavePanel?
    var closeApproved = false

    private let bookmarkCreator: (URL) throws -> Data
    init(bookmarkCreator: @escaping (URL) throws -> Data = ProjectSource.securityBookmark) {
        self.bookmarkCreator = bookmarkCreator
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
    private var repeatGutter: Double = 0
    private var revision = UUID()
    private var importRevision = UUID()

    var displaySheets: [Sheet] { plan.sheets+plan.diagnosticSheets }
    var currentSheet: Sheet? { displaySheets.indices.contains(sheetIndex) ? displaySheets[sheetIndex] : nil }
    var currentSide: Side? { currentSheet.map { side == .front ? $0.front : $0.back } }
    var highlightedSlots: Set<Int> {
        Set(plan.issues.compactMap { issue in
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
        guard plan.generatedBleed.enabled,let source,let side = currentSide else { samplingBleed = false; return }
        if plan.generatedBleed.method == .solidColor {
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
        exporting = true; exportSummary = nil; exportedFiles = []
        let worker = Task.detached(priority: .userInitiated) {
            defer { scopedParent?.stopAccessingSecurityScopedResource() }
            do { return try PDFExporter.export(plan: snapshot,source: source,destination: destination,marks: options,jobName: source.url.deletingPathExtension().lastPathComponent) }
            catch {
                if let cleanupOnFailure { try? FileManager.default.removeItem(at: cleanupOnFailure) }
                throw error
            }
        }
        exportTask = Task {
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                exportedFiles = result.files
                exportSummary = "Son çıktı hazır: \(result.sheetCount) tabaka · \(result.pageCount) sayfa · \(result.files.count) dosya"
            } catch is CancellationError { exportSummary = "Dışa aktarma iptal edildi." }
            catch { self.error = error.localizedDescription }
            exporting = false
        }
    }
    func setMode(_ mode: BindingMethod) {
        guard mode != project.binding else { return }
        var next = project
        if mode == .stepAndRepeat {
            bookletGutter = project.sheet.gutter
            next.sheet.gutter = repeatGutter
        } else if project.binding == .stepAndRepeat {
            repeatGutter = project.sheet.gutter
            next.sheet.gutter = bookletGutter ?? 6
        }
        next.binding = mode
        project = next
    }
    func openPanel() {
        if let filePanel { filePanel.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.allowedContentTypes = [.pdf,.projectFile]; panel.allowsMultipleSelection = false
        panel.title = "Aç"; panel.prompt = "Aç"
        panel.message = "AtışPress projesi (.atispress) veya PDF seçin"
        panel.begin { [weak self] response in
            self?.filePanel = nil
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }
    func open(_ url: URL,confirmChanges: Bool = true) {
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
                    var snapshot = baseline; snapshot.pages = source.pages.map(\.sourcePage)
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
                order = source.pages.map(\.number); included = Set(order); selectedPages = []
                sheetIndex = 0; repetition = 0
                applyAutomatic(prepared)
                loading = false
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
            let next = await Task.detached(priority: .userInitiated) {
                ImpositionPlanner.plan(snapshot)
            }.value
            guard !Task.isCancelled, revision == token else { return }
            plan = next; planning = false
            sheetIndex = max(0,min(sheetIndex,max(0,displaySheets.count-1)))
            repetition = max(0,min(repetition,(currentSheet?.repeatCount ?? 1)-1))
        }
    }
    func reveal(_ issue: ValidationIssue) {
        guard let ref = issue.slot else { return }
        sheetIndex = ref.sheet; side = ref.side
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,options: nil) { [weak self] item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data,relativeTo: nil) }
            else { url = item as? URL }
            Task { @MainActor in
                guard let url else { return }
                self?.open(url)
            }
        }
        return true
    }
}

extension Workspace {
    var state: ProjectState {
        ProjectState(project: project,source: sourceReference,order: order,included: included,
                     overlays: overlays,sheetPreset: sheetPreset,sheetIndex: sheetIndex,side: side,
                     bookletGutter: bookletGutter,repetition: repetition,repeatGutter: repeatGutter)
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
        source = nil; sourceReference = nil; projectURL = nil; projectAccess = nil
        order = []; included = []; selectedPages = []; overlays = PreviewOverlays(); sheetPreset = "33×48"
        bookletGutter = nil; repeatGutter = 0
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
        if let source, url.standardizedFileURL.resolvingSymlinksInPath() == source.url.standardizedFileURL.resolvingSymlinksInPath() {
            throw ProjectFileError.sourceOverwrite
        }
        let access = ProjectFileAccess(url)
        var snapshot = state
        if let source { snapshot.source = try ProjectSource.capture(source.url,createBookmark: bookmarkCreator) }
        try snapshot.validateSelection(pageCount: source?.pages.count ?? 0)
        try ProjectDocument(state: snapshot).encoded().write(to: url,options: .atomic)
        sourceReference = snapshot.source; projectURL = url; projectAccess = access
        savedState = snapshot; refreshModified()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
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
        if let reference = snapshot.source {
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
        source = loadedSource; sourceReference = snapshot.source
        projectURL = url; projectAccess = access
        order = snapshot.order; included = snapshot.included; selectedPages = []
        bookletGutter = snapshot.bookletGutter; repeatGutter = snapshot.repeatGutter
        sheetPreset = snapshot.sheetPreset; project = snapshot.project; overlays = snapshot.overlays
        sheetIndex = snapshot.sheetIndex; side = snapshot.side
        repetition = snapshot.repetition ?? 0; selectedSerialID = nil
        exportSummary = nil; exportedFiles = []; error = nil
        restoring = false
        // Refreshing a valid/stale bookmark alone is not a user edit; relinking is.
        savedState = snapshot; isModified = relinked
        if relinked { savedState?.source = file.state.source }
        schedulePlan()
        zoomFactor = 0; zoomAction += 1
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

extension Workspace {
    @discardableResult
    func addSerialField() -> UUID {
        let field = SerialField(jobIndex: currentSheet?.repeatLayout?.jobIndex ?? 0)
        project.serialFields.append(field); selectedSerialID = field.id
        return field.id
    }
    func duplicateSerialField(_ id: UUID) {
        guard var field = project.serialFields.first(where: { $0.id == id }) else { return }
        field.id = UUID(); field.position.x += 3; field.position.y += 3
        project.serialFields.append(field); selectedSerialID = field.id
    }
    func moveSerialField(_ id: UUID,to position: Point) {
        guard let index = project.serialFields.firstIndex(where: { $0.id == id }) else { return }
        project.serialFields[index].position = Point(position.x.rounded(),position.y.rounded())
    }
}

extension Workspace {
    func autoLabel(_ label: String,_ field: AutoLayoutField) -> String {
        if project.autoLayout?.automaticFields.contains(field) == true { return label+" · Otomatik" }
        if project.autoLayout?.manualFields.contains(field) == true { return label+" · Manuel" }
        return label
    }
    func markManual(_ field: AutoLayoutField) {
        guard !restoring,!applyingAutomatic else { return }
        var state = project.autoLayout ?? .legacy
        state.manualFields.insert(field); state.automaticFields.remove(field); state.summary = nil
        project.autoLayout = state
    }
    func autoBinding<T>(_ binding: Binding<T>,_ field: AutoLayoutField) -> Binding<T> {
        Binding(get: { binding.wrappedValue },set: { self.markManual(field); binding.wrappedValue = $0 })
    }
    func setProduction(_ production: ProductionType) {
        var state = project.autoLayout ?? .legacy; state.production = production
        project.autoLayout = state
        if !project.pages.isEmpty { autoArrange(resetOverrides: false) }
    }
    func autoArrange(resetOverrides: Bool = true) {
        guard !loading,!exporting,!autoArranging,!project.pages.isEmpty else { return }
        NSApp?.keyWindow?.makeFirstResponder(nil)
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
        if project.autoLayout?.manualFields.contains(.sheetSize) != true { sheetPreset = result.presetName }
        plan = result.plan; planning = false
        sheetIndex = max(0,min(sheetIndex,max(0,displaySheets.count-1)))
        repetition = max(0,min(repetition,(currentSheet?.repeatCount ?? 1)-1))
        applyingAutomatic = false
        warmGeneratedBleed(); refreshModified()
        zoomFactor = 0; zoomAction += 1
    }
}
