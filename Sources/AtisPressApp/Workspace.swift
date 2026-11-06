import SwiftUI
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

struct PreviewOverlays: Equatable {
    var crop = true
    var fold = true
    var bleed = true
    var safeArea = false
    var pageNumbers = true
    var sheetBoundary = true
    func shows(_ kind: MarkKind) -> Bool {
        switch kind {
        case .crop: return crop
        case .fold: return fold
        case .bleed: return bleed
        case .safeArea: return safeArea
        case .pageLabel: return pageNumbers
        case .margin, .gripper: return true
        }
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var project = Project(pages: [], binding: .saddleStitch,
        sheet: SheetSpec(preset: .cm50x70, margins: Insets(left: 10,right: 10,top: 10,bottom: 10),
                         gripperWidth: 10, gutter: 6)) {
        didSet { schedulePlan() }
    }
    @Published private(set) var source: PDFSource?
    @Published private(set) var plan = ImpositionPlan()
    @Published private(set) var order: [Int] = []
    @Published var included = Set<Int>()
    @Published var selectedPages = Set<Int>()
    @Published var sheetIndex = 0
    @Published var side: SideKind = .front
    @Published var overlays = PreviewOverlays()
    @Published var loading = false
    @Published var planning = false
    @Published var error: String?
    @Published var zoomAction = 0
    @Published var zoomFactor: CGFloat = 1
    private var filePanel: NSOpenPanel?
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
