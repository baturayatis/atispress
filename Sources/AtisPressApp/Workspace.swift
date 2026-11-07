import SwiftUI
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

typealias PreviewOverlays = PDFRenderOptions

@MainActor
final class Workspace: ObservableObject {
    @Published var project = Project(pages: [], binding: .stepAndRepeat,
        sheet: SheetSpec(preset: .cm50x70, margins: Insets(left: 10,right: 10,top: 10,bottom: 10),
                         gripperWidth: 10, gutter: 0)) {
        didSet {
            var previous = oldValue
            previous.exportMarks = project.exportMarks
            if previous != project { schedulePlan() }
        }
    }
    @Published private(set) var source: PDFSource?
    @Published private(set) var plan = ImpositionPlan()
    @Published private(set) var order: [Int] = []
    @Published var included = Set<Int>()
    @Published var selectedPages = Set<Int>()
    @Published var sheetIndex = 0 { didSet { warmGeneratedBleed() } }
    @Published var side: SideKind = .front { didSet { warmGeneratedBleed() } }
    @Published var overlays = PreviewOverlays()
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

    var currentSheet: Sheet? { plan.sheets.indices.contains(sheetIndex) ? plan.sheets[sheetIndex] : nil }
    var currentSide: Side? { currentSheet.map { side == .front ? $0.front : $0.back } }
    var highlightedSlots: Set<Int> {
        Set(plan.issues.compactMap { issue in
            guard let ref = issue.slot, ref.sheet == sheetIndex, ref.side == side else { return nil }
            return ref.slot
        })
    }
    var canExportNow: Bool {
        source != nil && plan.canExport && !plan.sheets.isEmpty && !planning && !loading && !exporting && !samplingBleed && !bleedSamplingFailed
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
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        panel.title = "PDF Aç"; panel.prompt = "Aç"
        panel.message = "Önizleme için bir PDF seçin"
        panel.begin { [weak self] response in
            self?.filePanel = nil
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }
    func open(_ url: URL) {
        importTask?.cancel()
        let token = UUID(); importRevision = token
        loading = true; error = nil
        importTask = Task {
            do {
                let source = try await PDFSource.open(url)
                guard !Task.isCancelled, importRevision == token else { return }
                plan = ImpositionPlan()
                self.source = source
                order = source.pages.map(\.number); included = Set(order); selectedPages = []
                sheetIndex = 0
                project.pages = source.pages.map(\.sourcePage)
                loading = false
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
            sheetIndex = min(sheetIndex,max(0,next.sheets.count-1))
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
