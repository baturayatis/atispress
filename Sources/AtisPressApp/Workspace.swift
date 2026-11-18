import SwiftUI
import Combine
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

typealias PreviewOverlays = PDFRenderOptions

@MainActor
final class Workspace: ObservableObject {
    let ui: UsabilitySettings
    private var uiSubscription: AnyCancellable?
    @Published private(set) var workflowRecommendation:WorkflowSheetRecommendation?
    private var workflowRecommendationTask:Task<Void,Never>?
    @Published var pendingSourceTrim:(id:UUID,trim:Size,bleed:Double)?
    @Published var showSplitAfterGuides=false
    @Published var showingArtworkSeparation = false
    @Published var showingPageSplit = false
    @Published var showingSourceGuides = false
    @Published var preparingSource = false
    @Published var preparingExport = false
    @Published var scaleWindow: ScaleWindowRequest?
    @Published var rescalePrompt: RescalePrompt?
    var pendingScalePrompts: [RescalePrompt] = []
    static let automaticSheetTitle = "Otomatik (ürüne göre)"
    static func newProject() -> Project {
        var p = Project(pages: [],binding: .stepAndRepeat,
            sheet: SheetSpec(preset: .sra3,margins: Insets(left: 10,right: 10,top: 10,bottom: 10),
                             gripperWidth: 0,gutter: 0))
        p.settings.generatedBleed.enabled = true
        p.alignment = .center
        p.stepAndRepeat.pageLayout = PageLayoutSettings()
        p.stepAndRepeat.waste = WasteSettings()
        p.sheetInfo = SheetInfoSettings()
        p.exportMarks.colorControls = ColorControlSettings()
        p.autoLayout = AutoLayoutSettings()
        p.autoLayout?.automaticFields.formUnion([.gutter,.alignment])
        return p
    }
    @Published var project = Workspace.newProject() {
        didSet {
            if !restoring && !applyingAutomatic && !trackingManual {
                var changed = AutoLayoutField.changes(from: oldValue,to: project)
                // Restoring a mode's remembered gutter is not an inspector edit.
                if oldValue.binding != project.binding { changed.remove(.gutter) }
                if project.binding == .stepAndRepeat && oldValue.binding == .stepAndRepeat {
                    if changed.contains(.gutter) {
                        trackingManual = true; project.stepAndRepeat.arrangement = .custom; trackingManual = false
                    } else if changed.contains(.bleed), project.stepAndRepeat.arrangement == .spaced,
                              project.autoLayout?.isFixed(.gutter) != true {
                        trackingManual = true; project.sheet.gutter = 2*project.settings.bleed; trackingManual = false
                    }
                }
                if !changed.isEmpty {
                    var state = project.autoLayout ?? .legacy
                    if changed.contains(.sheetSize) { state.sheetSelection = .fixed }
                    state.manualFields.formUnion(changed); state.automaticFields.subtract(changed); state.presetFields?.subtract(changed); state.summary = nil
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
            previous.costing = project.costing
            previous.allSheetsPreview = project.allSheetsPreview
            let clipChanged = (project.isBooklet && oldValue.includeBlankBacks != project.includeBlankBacks) || oldValue.usesFullSheetBooklet != project.usesFullSheetBooklet || (project.isBooklet && oldValue.hasActiveCropMarks != project.hasActiveCropMarks) || previous.autoLayout?.clipBleedToSheet != project.autoLayout?.clipBleedToSheet || previous.autoLayout?.trimTolerance != project.autoLayout?.trimTolerance
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
    @Published var pageDuplicateRequest:PageDuplicateRequest?
    @Published var pdfLoadFailure:PDFLoadFailure?
    @Published var pdfInsertion:PDFInsertionDraft?
    @Published var pdfInsertionIndex:Int?
    var pendingPDFScaleRequest:ScaleWindowRequest?
    func showPendingPDFScaleWindow() {if let request=pendingPDFScaleRequest {pendingPDFScaleRequest=nil;scaleWindow=request}}
    var importScalePages:[Int]?
    private var pdfImportSnapshot:EditSnapshot?
    var allowBacklessExportOnce=false
    @Published var sheetIndex = 0 { didSet {
        if oldValue != sheetIndex { repetition = 0 }
        warmGeneratedBleed()
    } }
    @Published var repetition = 0
    @Published var selectedSerialID: UUID?
    @Published var side: SideKind = .front { didSet { warmGeneratedBleed() } }
    static func defaultPreviewOverlays() -> PreviewOverlays { var options = PreviewOverlays(); options.pageNumbers = false; return options }
    @Published var overlays = Workspace.defaultPreviewOverlays() { didSet { refreshModified() } }
    @Published var sheetPreset = Workspace.automaticSheetTitle { didSet { refreshModified() } }
    @Published private(set) var isModified = false
    @Published private(set) var projectURL: URL?
    private var sourceReference: ProjectSource?
    private var savedState: ProjectState?
    private var projectIdentifier = UUID()
    var inspectorMemory = InspectorEditMemory()
    var inspectorMemoryKey:String { projectIdentifier.uuidString+project.binding.rawValue }
    private let journal = WorkspaceJournal()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var captureEditTask: Task<Void,Never>?
    private var finishEditTask: Task<Void,Never>?
    private var autosaveTask: Task<Void,Never>?
    private var autosaveTimer: Timer?
    private var persistenceEnabled = false
    private var recoveryStore = RecoveryStore()
    private var presetStore = PresetStore()
    @Published private(set) var presets: [JobPreset] = []
    @Published var selectedPresetID: UUID?
    private var checkedRecovery = false
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
         recentStore: RecentFilesStore? = nil,filePicker: FilePicker? = nil,uiDefaults:UserDefaults = .standard) {
        self.ui = UsabilitySettings(defaults:uiDefaults)
        self.bookmarkCreator = bookmarkCreator
        self.recentStore = recentStore ?? RecentFilesStore()
        self.filePicker = filePicker
        recentFiles = self.recentStore.files()
        savedState = state
        journal.reset(editSnapshot)
        uiSubscription = ui.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
    @Published private(set) var exportVerification:ExportVerification?
    @Published private(set) var exportNotes:[String] = []
    @Published private(set) var exportedFiles: [URL] = []
    @Published var zoomAutomatic = true
    @Published var zoomScale:CGFloat = 1
    var zoomStateLabel:String { zoomAutomatic ? "Otomatik sığdır" : "%\(Int((zoomScale*100).rounded()))" }
    @Published var zoomAction = 0 { didSet { zoomAutomatic = zoomFactor == 0 } }
    @Published var zoomFactor: CGFloat = 1
    private var filePanel: NSOpenPanel?
    private var exportPanel: NSSavePanel?
    private var exportTask: Task<Void,Never>?
    @Published private(set) var checkingBindingStrips = false
    private var bindingStripTask: Task<Void,Never>?
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
        source != nil && plan.canExport && !plan.sheets.isEmpty && !preparingSource && !planning && !loading && !autoArranging && !exporting && !samplingBleed && !bleedSamplingFailed
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
        let sampleSlots = project.sourcePreparation?.hasPreparedProducts == true ? (currentSheet.map { $0.front.slots+$0.back.slots } ?? side.slots) : side.slots
        let numbers = Array(Set(sampleSlots.compactMap(\.sourcePageNumber)))
        let scaled:[(Int,ArtworkRescale)] = project.sourcePreparation?.hasPreparedProducts == true ? sampleSlots.compactMap {slot in guard let n=slot.sourcePageNumber,let scale=slot.rescale else {return nil};return (n,scale)}:[]
        if numbers.allSatisfy({ source.edgeSamples.cached(page: $0) != nil }) && scaled.allSatisfy({source.edgeSamples.cached(page:$0.0,rescale:$0.1) != nil}) {
            let native = numbers.filter { source.edgeSamples.cached(page: $0)?.usesCMYK == true }.count
            let rgb = numbers.count-native
            bleedSampleSummary = "Kenar örnekleri: \(native) CMYK · \(rgb) RGB"+(rgb > 0 ? " (özgün CMYK kanalları korunmaz)" : "")
            samplingBleed = false; return
        }
        samplingBleed = true
        bleedTask = Task {
            do {
                try await source.prepareGeneratedBleed(pages: numbers,scaled:scaled)
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
        if requiresBacklessConfirmation && !allowBacklessExportOnce {
            let alert=NSAlert();alert.messageText="Arka yüz yok";alert.informativeText="Arka yüz baskıya girmeyecek. Bu şekilde dışa aktarılsın mı?"
            alert.addButton(withTitle:"Onayla ve dışa aktar");alert.addButton(withTitle:"Vazgeç")
            guard alert.runModal() == .alertFirstButtonReturn else {return}
        }
        allowBacklessExportOnce=false
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
        exporting = true; exportSummary = nil; exportedFiles = []; exportVerification = nil; exportNotes = []
        let worker = Task.detached(priority: .userInitiated) {
            defer { scopedParent?.stopAccessingSecurityScopedResource() }
            do {
                let result = try PDFExporter.export(plan:snapshot,source:source,destination:destination,marks:options,jobName:source.url.lastPathComponent,sheetInfo:sheetInfo,production:production,includeBlankBacks:includeBlankBacks)
                let verification:ExportVerification
                do { verification = try ExportVerification.check(files:result.files,plan:snapshot,source:source,marks:options,includeBlankBacks:includeBlankBacks) }
                catch is CancellationError { throw CancellationError() }
                catch { verification = ExportVerification(differences:["Çıktı doğrulanamadı; PDF yeniden okunamadı."]) }
                return (result,verification)
            }
            catch {
                if let cleanupOnFailure { try? FileManager.default.removeItem(at: cleanupOnFailure) }
                throw error
            }
        }
        exportTask = Task {
            do {
                let (result,verification) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                exportVerification = verification; exportNotes = result.notes
                exportedFiles = result.files
                let sizes = Array(Set(snapshot.sheets.map { TRFormat.size($0.size.width,$0.size.height) })).sorted().joined(separator:" / ")
                exportSummary = "PDF hazır · \(result.pageCount) sayfa · \(sizes)"
            } catch is CancellationError { exportSummary = "Dışa aktarma iptal edildi." }
            catch { self.error = error.localizedDescription }
            exporting = false
        }
    }
    func setMode(_ mode: BindingMethod) {
        guard mode != project.binding else { return }
        var next = project
        // Only flat/gang jobs own editable gutters. Never save a booklet's
        // obsolete fold gap into either cache, or restore it into a fold.
        if project.binding == .stepAndRepeat || project.isLeafBinding { repeatGutter = project.sheet.gutter }
        if project.binding == .gang { gangGutter = project.sheet.gutter }
        next.sheet.gutter = (mode == .stepAndRepeat || mode == .spiral || mode == .wireO) ? repeatGutter : mode == .gang ? (gangGutter ?? 0) : 0
        next.binding = mode
        if next.team != nil {
            next.team = nil
            if next.sourcePreparation?.separation == nil {
                next.gang = nil
                sourceReference = gangAssets.first?.saved.reference
                gangAssets = []
            }
        }
        if mode == .gang {
            if next.gang == nil {
                next.gang = GangSettings()
                if next.pageItems != nil,let source {
                    if gangAssets.isEmpty,let reference=sourceReference {
                        let id=project.sourcePreparation?.sourceID ?? state.projectID ?? UUID()
                        gangAssets=[GangAsset(saved:GangSourceReference(id:id,reference:reference,pageCount:source.pages.count),source:source)]
                        sourceReference=nil
                    }
                    if let fallback=gangAssets.first?.saved.id {
                        let jobs=next.repeatJobs.enumerated().map {index,pair -> GangJob in
                            let sourceID=next.pageItems?.first{$0.id==pair.front.number}?.sourceID ?? fallback
                            var job=GangJob(sourceID:sourceID,name:pageListTitle(pair.front.number),front:pair.front,back:pair.back)
                            job.internalCuts = next.internalCutJobs?[pair.front.number]
                            job.quantity=project.stepAndRepeat.quantity ?? 1000;job.waste=project.stepAndRepeat.waste ?? WasteSettings()
                            job.bleed=project.settings.bleed;job.generatedBleed=project.settings.generatedBleed
                            job.serialFields=project.serialFields.filter{$0.jobIndex==index}.map{var field=$0;field.id=UUID();field.jobIndex=0;return field}
                            return job
                        }
                        next.gang?.jobs=jobs
                        var original=project;original.migrateScaling();next.scaling=original.scaling;next.rescaleJobs=nil
                        next.scaling?.overrides=(original.scaling?.overrides ?? []).flatMap {value -> [ScalingOverride] in
                            jobs.enumerated().compactMap {index,job in
                                guard value.jobIndex==nil || value.jobIndex==index else {return nil}
                                var value=value;value.pages=value.pages.filter{$0==job.front.number || $0==job.back?.number}
                                value.jobIndex=nil;value.gangID=job.id
                                return value.pages.isEmpty ? nil:value
                            }
                        }
                    }
                } else if let source {
                    let id = project.sourcePreparation?.sourceID ?? UUID()
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
    @Published var showingTeamImportChoice = false

    func choosePDF() { chooseFile(.pdf) }

    func finishTeamImport(_ choice: TeamPDFImport, remember: Bool) {
        guard showingTeamImportChoice, canStartTeam, choice != .ask else { return }
        showingTeamImportChoice = false
        if remember { ui.teamPDFImport = choice }
        if choice == .team { startTeam() }
    }

    var canStartTeam: Bool {
        sourceReference != nil && (source?.pages.count ?? 0) > 1 && project.sourcePreparation == nil
    }

    func startTeam() {
        guard canStartTeam, let source, let reference = sourceReference else { return }
        showingTeamImportChoice = false
        rescalePrompt = nil
        pendingScalePrompts = []
        beginUndoGroup()
        defer { endUndoGroup() }
        let id = UUID()
        gangAssets = [GangAsset(saved: GangSourceReference(id: id, reference: reference, pageCount: source.pages.count), source: source)]
        sourceReference = nil
        var next = project
        var settings = TeamSettings()
        settings.quantity = next.stepAndRepeat.quantity ?? 1000
        settings.waste = next.stepAndRepeat.waste ?? WasteSettings()
        repeatGutter = next.sheet.gutter
        next.binding = .gang
        next.team = settings
        next.settings.turnMethod = .sheetwise
        next.pageItems = nil
        next.pageItemNextID = nil
        next.previouslyHadBacks = nil
        next.pages = source.pages.map(\.sourcePage)
        next.gang = GangSettings()
        let jobs = teamJobs(next, sourceID: id)
        next.gang?.jobs = jobs
        next.book = nil
        next.scaling = nil
        next.rescaleJobs = nil
        order = next.pages.map(\.number)
        included = Set(order)
        selectedPages = []
        project = next
        selectedGangJobID = next.gang?.jobs.first?.id
        selectPreviewSheet(0)
        overlays.pageNumbers = true
    }

    private func teamJobs(_ draft: Project, sourceID: UUID) -> [GangJob] {
        let step = draft.team?.duplex == true ? 2 : 1
        return stride(from: 0, to: draft.pages.count, by: step).map { index in
            let front = draft.pages[index]
            let back = step == 2 && index + 1 < draft.pages.count ? draft.pages[index + 1] : nil
            var job = GangJob(sourceID: sourceID, name: teamPageLabel(front, back), front: front, back: back)
            job.internalCuts = draft.gang?.jobs.first { $0.front.number == front.number }?.internalCuts
                ?? draft.internalCutJobs?[front.number]
            job.bleed = draft.settings.bleed
            job.generatedBleed = draft.settings.generatedBleed
            job.tint = (Double(index) * 0.61803398875 + 0.12).truncatingRemainder(dividingBy: 1)
            return job
        }
    }

    private func teamPageLabel(_ front: SourcePage, _ back: SourcePage?) -> String {
        back.map { "Sayfa \(front.number) / \($0.number)" } ?? "Sayfa \(front.number)"
    }

    func setTeamDuplex(_ duplex: Bool) {
        guard project.sourcePreparation?.separation == nil else { return }
        guard var team = project.team, let id = gangAssets.first?.saved.id else { return }
        var next = project
        team.duplex = duplex
        team.manualLayouts = nil
        if !duplex { next.settings.turnMethod = .sheetwise }
        next.team = team
        let jobs = teamJobs(next, sourceID: id)
        next.gang?.jobs = jobs
        project = next
        selectedGangJobID = next.gang?.jobs.first?.id
    }

    func swapTeamPage(jobID: UUID, side: SideKind, with number: Int) {
        guard project.sourcePreparation?.separation == nil else { return }
        guard var jobs = project.gang?.jobs, let target = jobs.firstIndex(where: { $0.id == jobID }),
              let sourceIndex = jobs.firstIndex(where: { $0.front.number == number || ($0.back?.number ?? 0) == number })
        else { return }
        let incomingIsFront = jobs[sourceIndex].front.number == number
        let outgoing = side == .front ? jobs[target].front : jobs[target].back
        let incoming = incomingIsFront ? jobs[sourceIndex].front : jobs[sourceIndex].back
        if (side == .front && incoming == nil) || (incomingIsFront && outgoing == nil) { return }
        if incomingIsFront, let outgoing { jobs[sourceIndex].front = outgoing }
        else { jobs[sourceIndex].back = outgoing }
        if side == .front, let incoming { jobs[target].front = incoming }
        else { jobs[target].back = incoming }
        for index in Set([target, sourceIndex]) {
            jobs[index].name = teamPageLabel(jobs[index].front, jobs[index].back)
            jobs[index].rescale = nil
        }
        project.gang?.jobs = jobs
    }
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
        if project.binding == .gang && project.team == nil && project.sourcePreparation?.hasPreparedProducts != true && project.sourcePreparation?.hiddenGuideGroups.isEmpty != false && url.pathExtension.lowercased() == "pdf" { addGangPDFs([url]); return }
        guard !preparingSource,!loading, !exporting, !autoArranging, (!confirmChanges || confirmDiscard()) else { return }
        showingTeamImportChoice = false
        if url.pathExtension.lowercased() == "atispress" {
            loading = true; error = nil; pdfLoadFailure=nil
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
        loading = true; error = nil; pdfLoadFailure=nil
        importTask = Task {
            do {
                let source = try await openPagePDF(url)
                guard !Task.isCancelled, importRevision == token else { return }
                var baseline = project
                var prepared: AutoLayoutResult
                while true {
                    var snapshot = baseline
                    if baseline.team != nil || baseline.sourcePreparation?.hasPreparedProducts == true ||
                        baseline.sourcePreparation?.hiddenGuideGroups.isEmpty == false {
                        snapshot.binding = .stepAndRepeat
                    }
                    snapshot.team = nil
                    snapshot.gang = nil
                    snapshot.internalCutJobs = nil
                    snapshot.pages = source.pages.map(\.sourcePage)
                    snapshot.pageItems = nil
                    snapshot.pageItemNextID = nil
                    snapshot.previouslyHadBacks = nil
                    snapshot.sourcePreparation = nil
                    snapshot.book?.coverSourceID = nil
                    snapshot.book?.coverPDFPages = []
                    snapshot.book?.auxiliaryPages = []
                    snapshot.book?.selection = CoverSelection()
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
                clearRecovery(); projectIdentifier = UUID()
                projectURL = nil; projectAccess = nil
                sourceReference = try? ProjectSource.capture(source.preparationInput.originalURL,createBookmark: bookmarkCreator)
                self.source = source
                gangAssets = []
                order = source.pages.map(\.number); included = Set(order); selectedPages = []
                sheetIndex = 0; repetition = 0
                applyAutomatic(prepared)
                zoomFactor = 0; zoomAction += 1
                loading = false
                resetJournal(); queueAutosave()
                recordRecentFile(source.originalURL)
                if canStartTeam && ui.teamPDFImport == .team {
                    startTeam()
                } else {
                    showingTeamImportChoice = canStartTeam && ui.teamPDFImport == .ask
                    offerRescaling()
                }
                refreshModified()
            } catch {
                guard !Task.isCancelled, importRevision == token else { return }
                loading = false
                if !(error is CancellationError) {
                    let failure=recordPDFLoadFailure(error,url:url,stage:"Ana PDF / ortak yükleyici")
                    pdfLoadFailure=failure;self.error=failure.localizedDescription
                }
            }
        }
    }
    func setIncluded(_ page: Int, _ value: Bool) {
        if value { included.insert(page) } else { included.remove(page) }
        updateSelection()
    }
    func includeAll(_ value: Bool) {
        if project.binding == .stepAndRepeat,project.pageItems==nil {
            var next=project;next.pageItems=pageListItems
            commitPageList(next,order:order,included:value ? Set(order):[],selection:selectedPages);return
        }
        included = value ? Set(order) : []; updateSelection()
    }
    func clearPageSources() {
        beginUndoGroup()
        var next=project;next.pages=[];next.pageItems=[];next.gang=nil;next.team=nil;next.sourcePreparation=nil
        next.book?.selection=CoverSelection();next.retargetPageListSettings(from:project,copies:[])
        next.book?.coverSourceID=nil;next.book?.coverPDFPages=[];next.book?.auxiliaryPages=[]
        gangAssets=[];source=nil;sourceReference=nil;order=[];included=[];selectedPages=[]
        project=next;endUndoGroup()
    }
    func capturePageSource(_ url:URL) throws -> ProjectSource {try ProjectSource.capture(url,createBookmark:bookmarkCreator)}
    func beginPDFImportScaling() {pdfImportSnapshot=editSnapshot;beginUndoGroup()}
    func finishPDFImportScaling(accepted:Bool) {
        guard let snapshot=pdfImportSnapshot else {return}
        if !accepted {restoreEdit(snapshot)}
        importScalePages=nil;pendingPDFScaleRequest=nil;pdfImportSnapshot=nil;endUndoGroup()
    }
    func commitPagePDFInsertion(_ value:Project,assets:[GangAsset],combined:PDFSource,order:[Int],included:Set<Int>,selection:Set<Int>) {
        beginUndoGroup()
        gangAssets=assets;source=combined;sourceReference=nil
        commitPageList(value,order:order,included:included,selection:selection)
        endUndoGroup()
    }
    func commitPageList(_ value:Project,order nextOrder:[Int],included nextIncluded:Set<Int>,selection:Set<Int>,copies:[[Int:Int]] = []) {
        beginUndoGroup()
        var next=value
        if hasActualPageBacks || project.previouslyHadBacks == true {next.previouslyHadBacks=true}
        if next.pageItems==nil,project.binding == .stepAndRepeat {next.pageItems=pageListItems}
        if var items=next.pageItems,project.binding == .stepAndRepeat {
            var newOrder=nextOrder,newIncluded=nextIncluded
            let maximum=max(items.map(\.id).max() ?? 0,source?.pages.count ?? 0)
            guard maximum<Int.max else {error="Sayfa kimliği sınırına ulaşıldı.";endUndoGroup();return}
            var id=max(next.pageItemNextID ?? 1,maximum+1)
            let frontPairs=Set(items.filter{$0.side == .front}.compactMap(\.pairID))
            for item in items where item.side == .back {
                guard let pair=item.pairID,!frontPairs.contains(pair) else {continue}
                guard id<Int.max else {endUndoGroup();return}
                var blank=PageListItem(id:id,sourcePage:nil,size:item.size);id+=1;blank.side = .front;blank.pairID=pair
                items.append(blank);newOrder.insert(blank.id,at:newOrder.firstIndex(of:item.id) ?? 0)
                if nextIncluded.contains(item.id) {newIncluded.insert(blank.id)}
            }
            next.pageItems=items;next.pageItemNextID=id
            next.pages=next.selectedPageList(order:newOrder,included:newIncluded)
            next.retargetPageListSettings(from:project,copies:copies)
            self.order=newOrder;self.included=newIncluded;selectedPages=selection
            if project.previouslyHadBacks == true || hasActualPageBacks {next.previouslyHadBacks=true}
            project=next;endUndoGroup();return
        }
        if let items=next.pageItems {
            let map=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)})
            next.pages=nextOrder.filter{nextIncluded.contains($0)}.compactMap{map[$0]?.planningPage}
        } else if let source {next.pages=nextOrder.filter{nextIncluded.contains($0)}.map{source.pages[$0-1].sourcePage}}
        next.retargetPageListSettings(from:project,copies:copies)
        order=nextOrder;included=nextIncluded;selectedPages=selection
        if project.resolvedPageLayout == .duplex || project.repeatJobs.contains(where:{$0.back != nil}) {next.previouslyHadBacks=true}
        project=next;endUndoGroup()
    }
    func updateSelection() {
        guard let source else { return }
        if let items=project.pageItems {
            let map=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)})
            project.pages=order.filter{included.contains($0)}.compactMap{map[$0]?.planningPage}
        } else {project.pages = order.filter { included.contains($0) }.map { source.pages[$0-1].sourcePage }}
    }
    func move(_ offsets: IndexSet, to destination: Int) {
        var next=order;next.move(fromOffsets:offsets,toOffset:destination)
        var value=project;if value.pageItems==nil {value.pageItems=pageListItems}
        commitPageList(value,order:next,included:included,selection:selectedPages)
    }
    func moveSelected(up: Bool) {
        guard !selectedPages.isEmpty else { return }
        var nextOrder=order
        if up {
            for index in nextOrder.indices.dropFirst() where selectedPages.contains(nextOrder[index]) && !selectedPages.contains(nextOrder[index-1]) {
                nextOrder.swapAt(index,index-1)
            }
        } else if nextOrder.count > 1 {
            for index in (0..<(nextOrder.count-1)).reversed() where selectedPages.contains(nextOrder[index]) && !selectedPages.contains(nextOrder[index+1]) {
                nextOrder.swapAt(index,index+1)
            }
        }
        var value=project;if value.pageItems==nil {value.pageItems=pageListItems}
        commitPageList(value,order:nextOrder,included:included,selection:selectedPages)
    }
    func schedulePlan() {
        planTask?.cancel()
        let token = UUID(); revision = token
        let snapshot = project
        guard snapshot.hasPanelItems else {plan=ImpositionPlan();planning=false;return}
        planning = true
        planTask = Task {
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { ImpositionPlanner.plan(snapshot) }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, revision == token else { return }
            plan = next; planning = false
            inspectBindingStrips()
            normalizeSerialDigits()
            sheetIndex = max(0,min(sheetIndex,max(0,displaySheets.count-1)))
            repetition = max(0,min(repetition,(currentSheet?.repeatCount ?? 1)-1))
            warmGeneratedBleed()
        }
    }
    func reveal(_ issue: ValidationIssue) {
        if let ref = issue.slot ?? issue.affectedSlots.first {
            sheetIndex = max(0,min(ref.sheet,max(0,displaySheets.count-1))); side = ref.side; repetition = 0
        } else {
            if issue.code == .gangLayout { ui.jump(.montage) }
            else { ui.reveal(inspectorSection(for:issue)) }
        }
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
            if project.binding == .gang,project.team == nil,project.sourcePreparation?.separation == nil,urls.allSatisfy({ $0.pathExtension.lowercased()=="pdf" }) { addGangPDFs(urls) }
            else if let url = urls.first { open(url) }
        }
        return true
    }
}

extension Workspace {
    var state: ProjectState {
        ProjectState(projectID:projectIdentifier,project: project,source: sourceReference,order: order,included: included,
                     overlays: overlays,sheetPreset: sheetPreset,sheetIndex: sheetIndex,side: side,
                     bookletGutter: bookletGutter,repetition: repetition,gangSources: gangAssets.isEmpty || project.book?.coverSourceID != nil ? nil : gangAssets.map(\.saved),repeatGutter: repeatGutter,gangGutter: project.binding == .gang ? project.sheet.gutter : gangGutter,linkedSources: project.book?.coverSourceID == nil ? nil : gangAssets.map(\.saved),sourcePageCount:project.pageItems == nil ? nil : (source?.pages.count ?? 0))
    }
    private func refreshModified() {
        guard !restoring else { return }
        // Navigation is saved but does not make a project dirty by itself.
        var current = state
        current.sheetIndex = savedState?.sheetIndex ?? 0; current.side = savedState?.side ?? .front
        current.repetition = savedState?.repetition
        isModified = current != savedState
        queueEditingCapture()
        queueAutosave()
    }
    func createNewProject() {
        guard !preparingSource,!loading,!exporting,!autoArranging,confirmDiscard() else { return }
        importTask?.cancel(); autoTask?.cancel(); autoArranging = false; planTask?.cancel(); bleedTask?.cancel()
        clearRecovery()
        showingTeamImportChoice = false
        restoring = true; projectIdentifier = UUID()
        gangAssets = []; selectedGangJobID = nil; selectedGangBlockID = nil
        source = nil; sourceReference = nil; projectURL = nil; projectAccess = nil
        order = []; included = []; selectedPages = []; overlays = Self.defaultPreviewOverlays(); sheetPreset = Self.automaticSheetTitle
        bookletGutter = nil; repeatGutter = 0; gangGutter = nil
        project = Self.newProject()
        planTask?.cancel(); revision = UUID()
        plan = ImpositionPlan(); sheetIndex = 0; side = .front; repetition = 0; selectedSerialID = nil
        planning = false; exportSummary = nil; exportVerification = nil; exportNotes = []; exportedFiles = []; error = nil
        restoring = false; savedState = state; isModified = false
        resetJournal()
        zoomFactor = 0; zoomAction += 1
    }
    @discardableResult
    func saveProject(as newURL: URL? = nil) throws -> URL {
        guard let url = newURL ?? projectURL else { throw CocoaError(.fileNoSuchFile) }
        if let source, source.protectedURLs.contains(where: { url.standardizedFileURL.resolvingSymlinksInPath() == $0.standardizedFileURL.resolvingSymlinksInPath() }) {
            throw ProjectFileError.sourceOverwrite
        }
        flushUndoEdits()
        let access = ProjectFileAccess(url)
        var snapshot = state
        if let source,gangAssets.isEmpty { snapshot.source = try ProjectSource.capture(source.preparationInput.originalURL,createBookmark: bookmarkCreator) }
        try snapshot.validateSelection(pageCount: source?.pages.count ?? 0)
        try ProjectDocument(state: snapshot).encoded().write(to: url,options: .atomic)
        sourceReference = snapshot.source; projectURL = url; projectAccess = access
        savedState = snapshot; refreshModified()
        clearRecovery(); journal.rebase(editSnapshot)
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
    func loadProject(at url: URL,relink: ((ProjectSource) -> URL?)? = nil,recovery: RecoveryRecord? = nil,password:((URL)->String?)? = nil) async throws {
        let represented = recovery?.originalProjectPath.map { URL(fileURLWithPath:$0) }
        let access = ProjectFileAccess(represented ?? url)
        let file = try recovery?.document ?? ProjectDocument.decode(Data(contentsOf: url))
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
                var loaded = try await openPagePDF(sourceURL!,password:password)
                guard loaded.pages.count == saved.pageCount else { throw ProjectFileError.sourceMismatch }
                if let preparation=snapshot.project.sourcePreparation,preparation.sourceID==saved.id { loaded = try await loaded.prepared(preparation) }
                let reference = try ProjectSource.capture(sourceURL!,createBookmark: bookmarkCreator)
                assets.append(GangAsset(saved: GangSourceReference(id: saved.id,reference: reference,pageCount: saved.pageCount),source: loaded))
            }
            if snapshot.project.team != nil, assets.count == 1 { loadedSource = assets[0].source }
            else { loadedSource = try await PDFSource.combine(assets.map(\.source),displayName:snapshot.project.book?.coverSourceID == nil ? nil : "Kitap ve kapak") }
            try snapshot.validateSelection(pageCount: loadedSource!.pages.count)
            for item in snapshot.project.pageItems ?? [] {
                guard let id=item.sourceID else {continue}
                guard let index=assets.firstIndex(where:{$0.saved.id==id}),let local=item.localPage,
                      local>0,local<=assets[index].source.pages.count,
                      item.sourcePage==assets.prefix(index).reduce(0,{$0+$1.source.pages.count})+local else {throw ProjectFileError.sourceMismatch}
            }
            guard snapshot.matchesPageMetadata(loadedSource!) else { throw ProjectFileError.sourceMismatch }
            for job in snapshot.project.gang?.jobs ?? [] {
                guard let assetIndex = assets.firstIndex(where: { $0.saved.id==job.sourceID }) else { throw ProjectFileError.sourceMismatch }
                let start = assets.prefix(assetIndex).reduce(0) { $0+$1.source.pages.count }
                for page in [job.front,job.back].compactMap({ $0 }) {
                    if let item=snapshot.project.pageItems?.first(where:{$0.id==page.number}) {
                        guard item.planningPage==page else {throw ProjectFileError.sourceMismatch}
                        if let number=item.sourcePage {
                            let owner=item.sourceID.flatMap{id in assets.firstIndex{$0.saved.id==id}} ?? assetIndex
                            let base=assets.prefix(owner).reduce(0){$0+$1.source.pages.count}
                            guard number>base,number<=base+assets[owner].source.pages.count else {throw ProjectFileError.sourceMismatch}
                        }
                    } else {
                        guard page.number>start,page.number<=start+assets[assetIndex].source.pages.count,loadedSource!.pages[page.number-1].sourcePage==page else { throw ProjectFileError.sourceMismatch }
                    }
                }
            }
            if let book = snapshot.project.book,let id = book.coverSourceID {
                guard let index = assets.firstIndex(where:{ $0.saved.id==id }) else { throw ProjectFileError.sourceMismatch }
                let offset = assets.prefix(index).reduce(0) { $0+$1.saved.pageCount }
                guard book.coverPDFPages.allSatisfy({ id in snapshot.project.artworkPageNumber(id).map{$0>offset && $0<=offset+assets[index].saved.pageCount} ?? false }),
                      book.auxiliaryPages.allSatisfy({ id in snapshot.project.artworkPageNumber(id).map{$0>0 && $0<=loadedSource!.pages.count} ?? false }) else { throw ProjectFileError.sourceMismatch }
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
            loadedSource = try await openPagePDF(sourceURL!,password:password)
            if let preparation=snapshot.project.sourcePreparation { loadedSource = try await loadedSource!.prepared(preparation) }
            try snapshot.validateSelection(pageCount: loadedSource!.pages.count)
            for item in snapshot.project.pageItems ?? [] {
                guard let id=item.sourceID else {continue}
                guard let index=assets.firstIndex(where:{$0.saved.id==id}),let local=item.localPage,
                      local>0,local<=assets[index].source.pages.count,
                      item.sourcePage==assets.prefix(index).reduce(0,{$0+$1.source.pages.count})+local else {throw ProjectFileError.sourceMismatch}
            }
            guard snapshot.matchesPageMetadata(loadedSource!) else { throw ProjectFileError.sourceMismatch }
            snapshot.source = try ProjectSource.capture(sourceURL!,createBookmark: bookmarkCreator)
        } else { try snapshot.validateSelection(pageCount: 0) }
        try Task.checkCancellation()
        clearRecovery()
        snapshot.projectID = snapshot.projectID ?? recovery?.id ?? UUID()
        showingTeamImportChoice = false
        restoring = true; projectIdentifier = snapshot.projectID!
        planTask?.cancel(); bleedTask?.cancel(); plan = ImpositionPlan()
        gangAssets = assets; selectedGangJobID = snapshot.project.gang?.jobs.first?.id; selectedGangBlockID = nil
        source = loadedSource; sourceReference = snapshot.source
        projectURL = recovery == nil ? url : represented; projectAccess = access
        order = snapshot.order; included = snapshot.included; selectedPages = []
        bookletGutter = snapshot.bookletGutter; repeatGutter = snapshot.repeatGutter; gangGutter = snapshot.gangGutter
        sheetPreset = snapshot.sheetPreset; project = snapshot.project; overlays = snapshot.overlays
        sheetIndex = snapshot.sheetIndex; side = snapshot.side
        repetition = snapshot.repetition ?? 0; selectedSerialID = nil
        exportSummary = nil; exportVerification = nil; exportNotes = []; exportedFiles = []; error = nil
        restoring = false
        // Refreshing a valid/stale bookmark alone is not a user edit; relinking is.
        savedState = recovery == nil ? snapshot : nil; isModified = relinked || recovery != nil
        resetJournal()
        if relinked { savedState?.source = file.state.source; savedState?.gangSources = file.state.gangSources; savedState?.linkedSources = file.state.linkedSources }
        schedulePlan()
        zoomFactor = 0; zoomAction += 1
        if recovery == nil { recordRecentFile(url) }
        else { try recoveryStore.write(RecoveryRecord(id:projectIdentifier,originalProjectPath:projectURL?.path,document:ProjectDocument(state:state))) }
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
    func moveSerialField(_ id: UUID,to position: Point,snap:Bool = true) {
        guard let index = editableSerialFields.firstIndex(where: { $0.id == id }) else { return }
        editableSerialFields[index].position = snap ? Point(position.x.rounded(),position.y.rounded()) : position
    }
}

extension Workspace {
    func autoLabel(_ label: String,_ field: AutoLayoutField) -> String {
        if label.contains(" · Otomatik") || label.contains(" · Manuel") || label.contains(" · Hazır ayar") { return label }
        if project.autoLayout?.presetFields?.contains(field) == true { return label+" · Hazır ayar" }
        if field == .sheetSize,(project.autoLayout?.sheetSelection ?? .fixed) == .fixed { return label+" · Manuel" }
        if project.autoLayout?.automaticFields.contains(field) == true { return label+" · Otomatik" }
        if project.autoLayout?.manualFields.contains(field) == true { return label+" · Manuel" }
        return label
    }
    func markManual(_ field: AutoLayoutField) {
        guard !restoring,!applyingAutomatic else { return }
        var state = project.autoLayout ?? .legacy
        if field == .sheetSize { state.sheetSelection = .fixed }
        state.manualFields.insert(field); state.automaticFields.remove(field); state.presetFields?.remove(field); state.summary = nil
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
        if !state.isFixed(.exportColorBar) {
            next.exportMarks.colorBar = production == .offset; state.automaticFields.insert(.exportColorBar)
        }
        if !state.isFixed(.exportTargets) {
            next.exportMarks.registrationTargets = production == .offset; state.automaticFields.insert(.exportTargets)
        }
        next.autoLayout = state
        applyingAutomatic = true; project = next; applyingAutomatic = false


        if !project.pages.isEmpty { autoArrange(resetOverrides: false) }
        else if state.sheetSelection == .automatic {
            applyingAutomatic = true
            project.sheet.size = production == .digital ? SheetPreset.sra3.size : SheetPreset.cm33x48.size
            if !state.isFixed(.gripperWidth) { project.sheet.gripperWidth = production == .digital ? 0 : 10 }
            applyingAutomatic = false
        }
        refreshModified()
    }
    func autoArrange(resetOverrides: Bool = true,askRescale: Bool = true) {
        guard !loading,!exporting,!autoArranging,!project.pages.isEmpty else { return }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        if resetOverrides && askRescale { _ = offerRescaling(arrangeAfter:true) }
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
            if resetOverrides { bookletGutter = nil; repeatGutter = 0; gangGutter = nil }
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
        inspectBindingStrips()
        sheetIndex = max(0,min(sheetIndex,max(0,displaySheets.count-1)))
        repetition = max(0,min(repetition,(currentSheet?.repeatCount ?? 1)-1))
        applyingAutomatic = false
        normalizeSerialDigits()
        warmGeneratedBleed(); refreshModified()
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
                let recipe = plan.sheets.lazy.compactMap { $0.gangLayout?.jobs.first { $0.job.id == job.id } }.first?.serialPlan
                gang.jobs[i].serialFields = job.serialFields.map { $0.adjustedDigits(quantity:max(quantity,recipe?.numberCount(for:$0) ?? quantity)) }
            }
            if gang != project.gang { normalizingDigits = true; project.gang = gang; normalizingDigits = false }
            return
        }
        let fields = editableSerialFields.map { field in
            let quantity = serialNumberedQuantity(job:field.jobIndex)
            let recipe = plan.sheets.first { $0.repeatLayout?.jobIndex == field.jobIndex }?.serialPlan
            return field.adjustedDigits(quantity:max(quantity,recipe?.numberCount(for:field) ?? quantity))
        }
        guard fields != editableSerialFields else { return }
        normalizingDigits = true; editableSerialFields = fields; normalizingDigits = false
    }
}

extension Workspace {
    var repeatArrangement: RepeatArrangement {
        project.stepAndRepeat.arrangement ?? (project.sheet.gutter == 0 ? .adjacent : .custom)
    }
    func setRepeatArrangement(_ arrangement: RepeatArrangement) {
        if repeatArrangement == .custom { inspectorMemory.customGutters[inspectorMemoryKey] = project.sheet.gutter }
        var next = project
        next.stepAndRepeat.arrangement = arrangement
        var state = next.autoLayout ?? .legacy
        state.summary = nil
        if arrangement == .custom {
            if let value = inspectorMemory.customGutters[inspectorMemoryKey] { next.sheet.gutter = value }
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
        if project.pageItems?.contains(where:{$0.side != nil}) == true {
            let jobs=project.repeatJobs,duplex=jobs.filter{$0.back != nil}.count
            return "\(duplex) çift yüz · \(jobs.count-duplex) tek yüz · Yüzler sayfa satırlarında gösterilir."
        }
        return mode + (pageLayoutMode == .automatic ? " · Otomatik" : " · Manuel")
    }
    func setPageLayout(_ mode: PageLayout) {
        if project.pageItems != nil {assignPageSides(mode);return}
        let had=hasActualPageBacks
        var next = project
        var settings = next.stepAndRepeat.pageLayout ?? PageLayoutSettings()
        settings.mode = mode; next.stepAndRepeat.pageLayout = settings
        if had {next.previouslyHadBacks=true}
        applyPageLayout(next)
    }
    func jobPageLayout(frontPage: Int) -> PageLayout {
        if let item=project.pageItems?.first(where:{$0.id==frontPage}) {return item.side == .single ? .simplex:.duplex}
        return project.stepAndRepeat.pageLayout?.overrides.last(where: { $0.frontPage == frontPage })?.layout ?? .automatic
    }
    func setJobPageLayout(frontPage: Int,mode: PageLayout) {
        if project.pageItems != nil {
            let duplex=mode == .duplex || (mode == .automatic && project.resolvedPageLayout == .duplex)
            setPageSide(frontPage,duplex ? .front:.single);return
        }
        var next = project
        if hasActualPageBacks {next.previouslyHadBacks=true}
        var settings = next.stepAndRepeat.pageLayout ?? PageLayoutSettings()
        if next.stepAndRepeat.pageLayout == nil { settings.mode = .duplex }
        settings.overrides.removeAll { $0.frontPage == frontPage }
        if mode != .automatic { settings.overrides.append(PageJobOverride(frontPage: frontPage,layout: mode)) }
        next.stepAndRepeat.pageLayout = settings
        applyPageLayout(next)
    }
    private func applyPageLayout(_ next: Project) {
        func key(_ p:Project) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(p.stepAndRepeat.pageLayout ?? PageLayoutSettings())) ?? Data()
            return inspectorMemoryKey+String(reflecting:p.pages)+data.base64EncodedString()
        }
        if let expected = inspectorMemory.lastMappedSerials,expected != project.serialFields { inspectorMemory.layoutSerials = [:] }
        inspectorMemory.layoutSerials[key(project)] = project.serialFields
        let remembered = inspectorMemory.layoutSerials[key(next)]
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
        if let remembered { next.serialFields = remembered }
        next.autoLayout?.summary = nil
        project = next
        inspectorMemory.lastMappedSerials = project.serialFields
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
        if project.team != nil { project.team?.quantity = quantity }
        else if let id = selectedGangJob?.id { editGangJob(id) { $0.quantity = quantity } }
        else { project.stepAndRepeat.quantity = quantity }
    }
    func editGangJob(_ id: UUID,_ edit: (inout GangJob) -> Void) {
        guard var next = project.gang,let i = next.jobs.firstIndex(where: { $0.id==id }) else { return }
        edit(&next.jobs[i]); project.gang = next
    }
    private func makeGangJobs(source: PDFSource,id: UUID,offset: Int,baseline: Project) -> [GangJob] {
        var single = baseline
        if baseline.pageItems == nil || offset != 0 {single.pages = source.pages.map(\.sourcePage)}
        return single.repeatJobs.enumerated().map { index,pair in
            var f = pair.front; f.number += offset
            var b = pair.back; b?.number += offset
            var job = GangJob(sourceID:id,name: source.url.deletingPathExtension().lastPathComponent+" · \(index+1)",front:f,back:b)
            job.internalCuts = baseline.internalCutJobs?[pair.front.number]
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
        guard !loading,!exporting,project.binding == .gang,project.team == nil,project.sourcePreparation?.separation == nil,!urls.isEmpty else { return }
        loading = true; error = nil; pdfLoadFailure=nil
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
                var next = project
                if next.pageItems != nil {
                    let oldSourceCount=assets.prefix(assets.count-urls.count).reduce(0){$0+$1.source.pages.count}
                    let addedPages=merged.pages.filter{$0.number>oldSourceCount}.map(\.sourcePage)
                    let mapping=try next.appendPageListSources(addedPages)
                    for index in settings.jobs.indices where index>=originalCount {
                        settings.jobs[index].front.number=mapping[settings.jobs[index].front.number]!
                        if let back=settings.jobs[index].back {settings.jobs[index].back?.number=mapping[back.number]!}
                    }
                    order+=addedPages.compactMap{mapping[$0.number]};included.formUnion(order.suffix(addedPages.count))
                    next.pages=next.selectedPageList(order:order,included:included)
                } else {
                    next.pages = merged.pages.map(\.sourcePage)
                    order = merged.pages.map(\.number); included = Set(order)
                }
                next.gang = settings;selectedPages = []
                project = next; selectedGangJobID = settings.jobs.last?.id
                recordRecentFile(urls.last!); schedulePlan()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            loading = false
            offerRescaling()
        }
    }
    func manualGang() {
        if project.team != nil {
            guard !planning, let sheet = currentSheet, plan.canExport else { return }
            var next = project
            next.sheet.orientation = sheet.size.width > sheet.size.height ? .landscape : .portrait
            next.team?.manualLayouts = plan.sheets.compactMap { $0.gangLayout?.blocks }
            project = next
            selectedGangBlockID = sheet.gangLayout?.blocks.first?.id
            return
        }
        guard let layout = currentSheet?.gangLayout else { return }
        var settings = project.gang ?? GangSettings(); settings.mode = .manual; settings.blocks = layout.blocks
        // Freeze the selected sheet orientation so a drag cannot change its coordinate frame.
        project.sheet.size = currentSheet!.size; project.sheet.orientation = currentSheet!.size.width>currentSheet!.size.height ? .landscape : .portrait
        project.gang = settings; selectedGangBlockID = settings.blocks.first?.id
    }
    func moveGangBlock(_ id: UUID,to origin: Point) {
        if project.team != nil {
            if project.team?.manualLayouts == nil { manualGang() }
            editTeamBlock(id) { $0.origin = Point(origin.x.rounded(), origin.y.rounded()) }
            selectedGangBlockID = id
            return
        }
        if project.gang?.mode != .manual { manualGang() }
        guard let i = project.gang?.blocks.firstIndex(where: { $0.id==id }) else { return }
        project.gang?.blocks[i].origin = Point(origin.x.rounded(),origin.y.rounded()); selectedGangBlockID = id
        selectedGangJobID = project.gang?.blocks[i].jobID
    }
    func swapTeamBlocks(_ first: UUID, _ second: UUID) {
        guard var plates = project.team?.manualLayouts, plates.indices.contains(sheetIndex),
              let a = plates[sheetIndex].firstIndex(where: { $0.id == first }),
              let b = plates[sheetIndex].firstIndex(where: { $0.id == second }) else { return }
        let origin = plates[sheetIndex][a].origin
        plates[sheetIndex][a].origin = plates[sheetIndex][b].origin
        plates[sheetIndex][b].origin = origin
        project.team?.manualLayouts = plates
    }
    func swapTeamPlacements(_ first: UUID, _ second: UUID) {
        guard first != second, var plates = project.team?.manualLayouts else { return }
        for sheet in plates.indices {
            for block in plates[sheet].indices {
                let id = plates[sheet][block].jobID
                if id == first { plates[sheet][block].jobID = second }
                else if id == second { plates[sheet][block].jobID = first }
            }
        }
        project.team?.manualLayouts = plates
    }
    func editTeamBlock(_ id: UUID, _ edit: (inout GangBlock) -> Void) {
        guard var plates = project.team?.manualLayouts, plates.indices.contains(sheetIndex),
              let index = plates[sheetIndex].firstIndex(where: { $0.id == id }) else { return }
        edit(&plates[sheetIndex][index])
        project.team?.manualLayouts = plates
    }
    func removeGangJob(_ id: UUID) {
        project.gang?.jobs.removeAll { $0.id==id }; project.gang?.blocks.removeAll { $0.jobID==id }
        selectedGangJobID = project.gang?.jobs.first?.id; selectedGangBlockID = project.gang?.blocks.first?.id; selectedSerialID = nil
    }
}

extension Workspace {
    var editableGeneratedBleed: GeneratedBleedSettings {
        get { selectedGangJob?.generatedBleed ?? project.settings.generatedBleed }
        set { inspectorMemory.bleedOrigins = [:]; if let id = selectedGangJob?.id { editGangJob(id) { $0.generatedBleed = newValue } } else { project.settings.generatedBleed = newValue } }
    }
    func gangSourcePages(_ id: UUID) -> [SourcePage] {
        guard let i = gangAssets.firstIndex(where: { $0.saved.id==id }) else { return [] }
        let offset = gangAssets.prefix(i).reduce(0) { $0+$1.source.pages.count }
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
        if project.pageItems != nil {return pageListTitle(number)}
        var offset = 0
        for asset in gangAssets {
            if number>offset && number<=offset+asset.saved.pageCount { return "\(number-offset) · \(asset.saved.reference.fileName)" }
            offset += asset.saved.pageCount
        }
        return "\(number)"
    }
    func chooseCoverPDF() {
        guard source != nil,!loading,!exporting,(project.isBooklet || project.isLeafBinding) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        panel.title = "Ayrı kapak PDF’sini seçin"; panel.prompt = "Kapak yükle"
        panel.begin { [weak self] response in if response == .OK,let url = panel.url { self?.loadCoverPDF(url) } }
    }
    func loadCoverPDF(_ url: URL) {
        guard let current = source,!loading,!exporting,(project.isBooklet || project.isLeafBinding) else { return }
        loading = true; error = nil; pdfLoadFailure=nil
        importTask = Task {
            do {
                let cover = try await openPagePDF(url)
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
                guard project.isBooklet || project.isLeafBinding else { throw CancellationError() }
                var next = project,book = next.book ?? BookSettings()
                let addedPages=combined.pages.filter{$0.number>offset}.map(\.sourcePage)
                let mapping=try next.appendPageListSources(addedPages)
                book.coverSourceID = id; book.coverPDFPages = addedPages.compactMap{mapping[$0.number]}
                book.auxiliaryPages = Array(Set(book.auxiliaryPages+book.coverPDFPages)).sorted()
                book.selection = CoverSelection()
                next.book = book; next.coverMode = .separate
                let selected = included.union(book.coverPDFPages)
                let newOrder = order+book.coverPDFPages
                if next.pageItems != nil {next.pages=next.selectedPageList(order:newOrder,included:selected)}
                else {next.pages = newOrder.filter { selected.contains($0) }.map { combined.pages[$0-1].sourcePage }}
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

extension Workspace {
    var blankSettings: BlankPlacement {
        get { project.blankPlacement ?? BlankPlacement() }
        set { project.blankPlacement = newValue }
    }
    func setBlankPosition(_ position: Int,selected: Bool) {
        var setting = blankSettings
        if selected { setting.positions = Array(Set(setting.positions+[position])).sorted() }
        else { setting.positions.removeAll { $0==position } }
        project.blankPlacement = setting
    }
}

extension Workspace {
    var hasManualLayoutSettings: Bool {
        !(project.autoLayout?.manualFields.isEmpty ?? false) || (project.autoLayout?.sheetSelection ?? .fixed) == .fixed || project.gang?.mode == .manual
    }
    func isManual(_ field: AutoLayoutField) -> Bool {
        if project.autoLayout?.presetFields?.contains(field) == true { return false }
        return project.autoLayout?.manualFields.contains(field) == true || (field == .sheetSize && (project.autoLayout?.sheetSelection ?? .fixed) == .fixed)
    }
    func requestAutomaticLayout(confirm: ((String) -> Bool)? = nil) {
        guard !loading,!exporting,!autoArranging,!project.pages.isEmpty else { return }
        if project.team != nil { project.team?.manualLayouts = nil; return }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        if hasManualLayoutSettings {
            let message = "Elle yapılan ayarlar sıfırlanacak."
            if let confirm { guard confirm(message) else { return } }
            else {
                let alert = NSAlert(); alert.messageText = message
                alert.informativeText = "Tabaka, yön, kenar payları, maşa, ara boşluk, taşma, işaretler, döndürme ve hizalama yeniden otomatik hesaplanır."
                alert.addButton(withTitle:"Sıfırla ve düzenle"); alert.addButton(withTitle:"İptal")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        autoArrange(resetOverrides:true)
    }
    func returnToAutomatic(_ field: AutoLayoutField) { returnToAutomatic([field]) }
    func returnToAutomatic(_ fields:[AutoLayoutField]) {
        guard !loading,!exporting,!autoArranging else { return }
        var next = project,state = project.autoLayout ?? .legacy
        for field in fields {
            state.manualFields.remove(field); state.presetFields?.remove(field); state.automaticFields.insert(field); state.summary = nil
            if field == .sheetSize { state.sheetSelection = .automatic }
            if field == .gutter { next.stepAndRepeat.arrangement = .adjacent }
            if field == .alignment { next.blockAlignment = .center }
            if field == .columns { next.stepAndRepeat.columns = nil }
            if field == .rows { next.stepAndRepeat.rows = nil }
            if let selected = selectedGangJob,let i = next.gang?.jobs.firstIndex(where:{ $0.id==selected.id }) {
                var job = next.gang!.jobs[i]
                switch field {
                case .generatedEnabled: job.generatedBleed.enabled = [job.front,job.back].compactMap { $0 }.contains { ($0.availableBleed ?? 0)<job.bleed }
                case .generatedMethod: job.generatedBleed.method = .automatic
                case .generatedTolerance: job.generatedBleed.tolerance = 0.02
                case .generatedColor: job.generatedBleed.color = .cmyk(0,0,0,0)
                default: break
                }
                next.gang?.jobs[i] = job
            }
        }
        next.autoLayout = state
        applyingAutomatic = true; project = next; applyingAutomatic = false
        autoArrange(resetOverrides:false)
    }
}


extension Workspace {
    private func inspectBindingStrips() {
        bindingStripTask?.cancel()
        guard let source else { checkingBindingStrips = false; return }
        let snapshot = plan,projectSnapshot = project
        checkingBindingStrips = true
        bindingStripTask = Task {
            let worker = Task.detached(priority:.utility) {
                PDFBindingStripInspector.warnings(plan:snapshot,url:source.url,cache:source.bindingStripCache)
            }
            let warnings = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            guard project == projectSnapshot,self.source?.id == source.id else { checkingBindingStrips = false; return }
            plan.issues += warnings; plan.refreshWarningSummary(project:project)
            checkingBindingStrips = false
        }
    }
}

// Editing services are inactive on disk until the real app starts them. Tests can
// inject isolated directories; creating a Workspace alone never writes recovery.
extension Workspace {
    private var editSnapshot: EditSnapshot { EditSnapshot(state:state,source:source,assets:gangAssets) }
    private func updateUndoAvailability() { canUndo = journal.canUndo; canRedo = journal.canRedo }
    private func queueEditingCapture() {
        guard captureEditTask == nil else { return }
        captureEditTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled,let self else { return }
            self.captureEditTask = nil
            self.captureCurrentEdit()
        }
    }
    private func captureCurrentEdit() {
        guard !restoring else { return }
        journal.observe(editSnapshot); updateUndoAvailability()
        finishEditTask?.cancel()
        finishEditTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(650))
            guard !Task.isCancelled,let self else { return }
            self.journal.flush(); self.updateUndoAvailability()
        }
    }
    private func resetJournal() {
        captureEditTask?.cancel(); captureEditTask = nil; finishEditTask?.cancel()
        journal.reset(editSnapshot); updateUndoAvailability()
    }
    func flushUndoEdits() {
        captureEditTask?.cancel(); captureEditTask = nil; finishEditTask?.cancel()
        journal.observe(editSnapshot); journal.flush(); updateUndoAvailability()
    }
    func beginUndoGroup() { flushUndoEdits(); journal.beginGroup() }
    func endUndoGroup() { captureCurrentEdit(); journal.endGroup(); updateUndoAvailability() }
    func undoEdit() {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        guard !preparingSource,!loading,!exporting,!autoArranging else { return }
        flushUndoEdits(); if let snapshot = journal.undo() { restoreEdit(snapshot) }; updateUndoAvailability()
    }
    func redoEdit() {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        guard !preparingSource,!loading,!exporting,!autoArranging else { return }
        flushUndoEdits(); if let snapshot = journal.redo() { restoreEdit(snapshot) }; updateUndoAvailability()
    }
    private func restoreEdit(_ snapshot: EditSnapshot) {
        restoring = true
        planTask?.cancel(); bleedTask?.cancel(); bindingStripTask?.cancel()
        source = snapshot.source; gangAssets = snapshot.assets; sourceReference = snapshot.state.source
        order = snapshot.state.order; included = snapshot.state.included; selectedPages.formIntersection(Set(order))
        bookletGutter = snapshot.state.bookletGutter; repeatGutter = snapshot.state.repeatGutter; gangGutter = snapshot.state.gangGutter
        project = snapshot.state.project; overlays = snapshot.state.overlays; sheetPreset = snapshot.state.sheetPreset
        sheetIndex = snapshot.state.sheetIndex; side = snapshot.state.side; repetition = snapshot.state.repetition ?? 0
        selectedSerialID = nil; selectedGangBlockID = nil; selectedGangJobID = project.gang?.jobs.first?.id
        restoring = false
        journal.rebase(editSnapshot); refreshModified(); schedulePlan()
    }
    func startPersistence(recovery: RecoveryStore? = nil,presetLibrary: PresetStore? = nil,autosaveInterval: TimeInterval = 30) {
        guard !persistenceEnabled else { return }
        if let recovery { recoveryStore = recovery }; if let presetLibrary { presetStore = presetLibrary }
        persistenceEnabled = true
        do { presets = try presetStore.load(); selectedPresetID = presets.first?.id } catch { self.error = error.localizedDescription }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval:autosaveInterval,repeats:true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performAutosave() }
        }
    }
    private func queueAutosave() {
        guard persistenceEnabled else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.performAutosave()
        }
    }
    private func performAutosave() {
        do { try autosaveNow() } catch { self.error = "Kurtarma kaydı yazılamadı: "+error.localizedDescription }
    }
    func autosaveNow() throws {
        guard persistenceEnabled,!loading,!restoring else { return }
        guard isModified else { try recoveryStore.remove(projectIdentifier); return }
        var snapshot = state
        if let source,gangAssets.isEmpty { snapshot.source = try ProjectSource.capture(source.preparationInput.url,createBookmark:bookmarkCreator) }
        try snapshot.validateSelection(pageCount:source?.pages.count ?? 0)
        try recoveryStore.write(RecoveryRecord(id:projectIdentifier,originalProjectPath:projectURL?.path,document:ProjectDocument(state:snapshot)))
    }
    private func clearRecovery() {
        autosaveTask?.cancel()
        guard persistenceEnabled else { return }
        do { try recoveryStore.remove(projectIdentifier) } catch { self.error = "Kurtarma kaydı temizlenemedi: "+error.localizedDescription }
    }
    func cleanRecoveryForNormalQuit() {
        autosaveTask?.cancel(); autosaveTimer?.invalidate(); autosaveTimer = nil
        clearRecovery(); persistenceEnabled = false
    }
    func restoreRecovery(_ record: RecoveryRecord,relink: ((ProjectSource)->URL?)? = nil) async throws {
        try await loadProject(at:recoveryStore.url(record.id),relink:relink ?? { [weak self] in self?.chooseRelink($0) },recovery:record)
    }
    func offerRecoveryOnLaunch() async {
        guard !checkedRecovery else { return }; checkedRecovery = true
        do {
            for record in try recoveryStore.records() {
                let alert = NSAlert(); alert.messageText = "Kurtarılan proje bulundu"
                alert.informativeText = (record.originalProjectPath.map { URL(fileURLWithPath:$0).lastPathComponent } ?? "Kaydedilmemiş yeni proje")+" · "+record.savedAt.formatted()
                alert.addButton(withTitle:"Geri yükle"); alert.addButton(withTitle:"Sil")
                if alert.runModal() == .alertFirstButtonReturn { try await restoreRecovery(record); break }
                try recoveryStore.remove(record.id)
            }
        } catch is CancellationError { } catch { self.error = "Kurtarma açılamadı: "+error.localizedDescription }
    }
    func applyPreset(_ preset: JobPreset) {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        guard !loading,!exporting,!autoArranging else { return }
        beginUndoGroup()
        applyingAutomatic = true
        project = preset.settings.apply(to:project,name:preset.name); overlays = preset.settings.overlays
        sheetPreset = SmartAutoLayout.presetName(for:project.sheet.size)
        if project.binding == .stepAndRepeat || project.isLeafBinding { repeatGutter = project.sheet.gutter }
        if project.binding == .gang { gangGutter = project.sheet.gutter }
        applyingAutomatic = false
        selectedPresetID = preset.id; refreshModified(); schedulePlan(); endUndoGroup()
    }
    @discardableResult
    func savePreset(name: String) throws -> JobPreset {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresetError.invalidPack }
        let preset = JobPreset(name:name,settings:PresetSettings(project:project,overlays:overlays))
        let next = presets+[preset]; try presetStore.save(next); presets = next; selectedPresetID = preset.id; return preset
    }
    func renamePreset(_ id: UUID,to name: String) throws {
        guard let index = presets.firstIndex(where:{ $0.id==id }),!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw PresetError.invalidPack }
        var next = presets; next[index].name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        try presetStore.save(next); presets = next
    }
    func deletePreset(_ id: UUID) throws {
        let next = presets.filter { $0.id != id }; try presetStore.save(next); presets = next; selectedPresetID = next.first?.id
    }
    func duplicatePreset(_ id: UUID) throws {
        guard var preset = presets.first(where:{ $0.id==id }) else { return }
        preset.id = UUID(); preset.name += " kopyası"
        let next = presets+[preset]; try presetStore.save(next); presets = next; selectedPresetID = preset.id
    }
    func exportPresets(to url: URL) throws { try PresetPack(presets:presets).encoded().write(to:url,options:.atomic) }
    func importPresets(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let imported = try PresetPack.decode(Data(contentsOf:url)).presets.map { original in var p = original; p.id = UUID(); return p }
        guard presets.count+imported.count<=1000 else { throw PresetError.invalidPack }
        let next = presets+imported; try presetStore.save(next); presets = next
    }
}

extension Workspace {
    func promptSavePreset() {
        guard let name = presetNameDialog(title:"Yeni hazır ayar kaydet",initial:"") else { return }
        do { _ = try savePreset(name:name) } catch { self.error = error.localizedDescription }
    }
    func promptRenamePreset() {
        guard let preset = presets.first(where:{ $0.id==selectedPresetID }),let name = presetNameDialog(title:"Hazır ayarı yeniden adlandır",initial:preset.name) else { return }
        do { try renamePreset(preset.id,to:name) } catch { self.error = error.localizedDescription }
    }
    private func presetNameDialog(title: String,initial: String) -> String? {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string:initial); field.frame = NSRect(x:0,y:0,width:300,height:24); field.placeholderString = "Hazır ayar adı"
        alert.accessoryView = field; alert.addButton(withTitle:"Kaydet"); alert.addButton(withTitle:"İptal")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }; return field.stringValue
    }
    func choosePresetExport() {
        let panel = NSSavePanel(); panel.title = "Hazır ayar paketini dışa aktar"; panel.allowedContentTypes = [.atispresetpack]
        panel.nameFieldStringValue = "Hazır ayarlar.atispresetpack"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try exportPresets(to:url) } catch { self.error = error.localizedDescription }
    }
    func choosePresetImport() {
        let panel = NSOpenPanel(); panel.title = "Hazır ayar paketi seçin"; panel.allowedContentTypes = [.atispresetpack]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try importPresets(from:url) } catch { self.error = error.localizedDescription }
    }
}


extension Workspace {
    var productKind: ProductKind {
        if let chosen = ui.productOverride(for:projectIdentifier),chosen.binding == project.binding { return chosen }
        return ProductKind.detect(project)
    }
    var basicQuantity:Int? {
        get {
            if let team = project.team { return team.quantity }
            if let job = selectedGangJob { return job.quantity }
            return project.isBooklet || project.isLeafBinding ? project.costing?.copies : project.stepAndRepeat.quantity
        }
        set {
            if project.team != nil { project.team?.quantity = newValue ?? 0 }
            else if let job = selectedGangJob { editGangJob(job.id) { $0.quantity = newValue ?? 0 } }
            else if project.isBooklet || project.isLeafBinding { var cost = project.costing ?? JobCostSettings(); cost.copies = newValue; project.costing = cost }
            else { project.stepAndRepeat.quantity = newValue }
        }
    }
    func setProductKind(_ kind:ProductKind) { ui.setProduct(kind,for:projectIdentifier); setMode(kind.binding) }
    func inspectorSection(for issue:ValidationIssue) -> InspectorSection {
        switch issue.code {
        case .missingBleed,.sharedCutBleed,.insufficientGutter: return .marks
        case .serialNumbering: return .serial
        case .bookSettings,.bindingAllowance,.unsupportedCover,.pageCountPadding: return .binding
        case .exceedsSheet: return .sheet
        default: return .product
        }
    }
    func resetInspectorSection(_ section:InspectorSection) {
        guard !loading,!exporting,!autoArranging else { return }
        if section == .serial {
            var fields = editableSerialFields
            for i in fields.indices { fields[i].digitsAreManual = false }
            editableSerialFields = fields; normalizeSerialDigits(); return
        }
        if section == .binding {
            var next = project
            if next.book != nil { next.book?.selection = CoverSelection() }
            next.blankPlacement = nil
            next.settings.signatureSize = .automatic
            project = next; return
        }
        if section == .price {
            guard var cost = project.costing else { return }
            cost.paper?.override = nil; cost.printing?.override = nil
            for i in cost.finishing.indices { cost.finishing[i].override = nil }
            cost.margin = nil; cost.vat = nil; project.costing = cost; return
        }
        if section == .product { ui.setProduct(nil,for:projectIdentifier) }
        let fields = section.fields
        guard !fields.isEmpty else { return }
        var next = project, state = project.autoLayout ?? .legacy
        state.manualFields.subtract(fields); state.presetFields?.subtract(fields); state.automaticFields.formUnion(fields); state.summary = nil
        if fields.contains(.sheetSize) { state.sheetSelection = .automatic }
        if fields.contains(.columns) { next.stepAndRepeat.columns = nil }
        if fields.contains(.rows) { next.stepAndRepeat.rows = nil }
        if fields.contains(.gutter) { next.stepAndRepeat.arrangement = .adjacent }
        next.autoLayout = state
        applyingAutomatic = true; project = next; applyingAutomatic = false
        autoArrange(resetOverrides:false,askRescale:false)
    }
    func sectionBadge(_ section:InspectorSection) -> String {
        if section == .serial { return editableSerialFields.contains { $0.digitsAreManual } ? "Manuel" : "Otomatik" }
        if section == .binding { return project.book != nil || project.leafBinding != nil || project.settings.signatureSize != .automatic ? "Manuel" : "Otomatik" }
        if section == .price {
            guard let cost = project.costing else { return "Otomatik" }
            return cost.paper?.override != nil || cost.printing?.override != nil || cost.finishing.contains { $0.override != nil } || cost.margin != nil || cost.vat != nil ? "Manuel" : "Otomatik"
        }
        return section.fields.contains(where: { isManual($0) || project.autoLayout?.presetFields?.contains($0) == true }) ? "Manuel" : "Otomatik"
    }
    var statusSummary:String {
        guard project.hasPanelItems else {return source==nil ? "PDF seçin":"Baskıya dahil sayfa yok"}
        let scaleSuffix = (scalingStatus.isEmpty ? "" : " · "+scalingStatus)+(requiresBacklessConfirmation ? " · Arka yüz yok":"")
        let copies = currentSheet?.repeatLayout?.copiesPerSheet ?? currentSheet?.front.slots.filter { $0.sourcePageNumber != nil }.count ?? 0
        if project.isBooklet || project.isLeafBinding {
            let label = project.isLeafBinding ? "yaprak/tabaka" : "sayfa/yüz"
            let count = currentSheet?.leafInfo.map { $0.copiesPerSheet*$0.setsPerSheet } ?? copies
            return "\(plan.totalPressSheets) tabaka · \(count) \(label) · Yayın adedi \(basicQuantity.map(String.init) ?? "girilmedi")"+scaleSuffix
        }
        if project.binding == .gang { return "\(plan.totalPressSheets) tabaka · \(copies) adet/tabaka · İş adedi \(basicQuantity.map(String.init) ?? "—")"+scaleSuffix }
        let quantity = currentSheet?.producedQuantityDescription ?? "—"
        return "\(plan.totalPressSheets) tabaka · \(copies) adet/tabaka · Üretim \(quantity) adet"+scaleSuffix
    }
}


extension Workspace {
    var workflowProductSummary:String {
        if let team = project.team {
            return "Takım Düzeni · \(project.pages.count) sayfa · \(team.duplex ? "çift yüz" : "tek yüz")"
        }
        guard let size = project.pages.first?.trimSize else { return "PDF seçerek başlayın" }
        return "\(productKind.rawValue) · \(TRFormat.size(size.width,size.height)) · \(project.resolvedPageLayout == .simplex ? "tek yüz" : "çift yüz")"
    }
    var selectedWorkflowChip:String {
        if project.autoLayout?.sheetSelection == .automatic { return "Otomatik" }
        if sheetPreset == "Özel" { return "Özel ölçü…" }
        return WorkflowPresentation.sheetPresets.first { $0.value.size == project.sheet.size }?.key ?? "Özel ölçü…"
    }
    func selectWorkflowSheet(_ chip:String) {
        if chip == "Otomatik" { returnToAutomaticSheet(); return }
        markManual(.sheetSize)
        if let preset = WorkflowPresentation.sheetPresets[chip] {
            sheetPreset = chip
            var next = project
            next.sheet.size = preset.size
            if workflowOrientation == .auto { next.sheet.orientation = .auto }
            applyingAutomatic = true; project = next; applyingAutomatic = false
            schedulePlan()
        }
        else {
            sheetPreset = "Özel"
            if workflowOrientation == .auto { selectWorkflowOrientation(.auto) }
        }
    }
    /// Resolved automatic geometry is not a manual orientation choice.
    var workflowOrientation:Orientation {
        (project.autoLayout ?? .legacy).isFixed(.orientation) ? project.sheet.orientation : .auto
    }
    func selectWorkflowOrientation(_ orientation:Orientation) {
        var next = project
        var state = next.autoLayout ?? .legacy
        state.presetFields?.remove(.orientation)
        if orientation == .auto { state.manualFields.remove(.orientation); state.automaticFields.insert(.orientation) }
        else { state.manualFields.insert(.orientation); state.automaticFields.remove(.orientation) }
        next.autoLayout = state; next.sheet.orientation = orientation
        applyingAutomatic = true; project = next; applyingAutomatic = false
        schedulePlan()
    }
    var workflowOrientationSummary:String {
        let size = currentSheet?.size ?? project.sheet.size
        return "Seçili: \(size.width > size.height ? "Yatay" : "Dikey") · \(TRFormat.size(size.width,size.height))"
    }
    var workflowWaste:WasteSettings {
        get { project.team?.waste ?? selectedGangJob?.waste ?? project.stepAndRepeat.waste ?? WasteSettings() }
        set { if project.team != nil { project.team?.waste = newValue } else if let job = selectedGangJob { editGangJob(job.id) { $0.waste = newValue } } else { project.stepAndRepeat.waste = newValue } }
    }
    func workflowAddonSummary(_ addon:WorkflowAddon) -> String? {
        switch addon {
        case .serial: return editableSerialFields.isEmpty ? nil : "\(editableSerialFields.count) alan yapılandırıldı"
        case .scaling: return project.hasRescaling ? scalingSummary : nil
        case .color: return project.exportMarks.colorBar || project.exportMarks.registrationTargets ? "Çıktı işaretleri etkin" : nil
        case .info: return project.exportMarks.sheetInfo ? "Çıktıda etkin" : nil
        case .pricing: return project.costing == nil ? nil : "Bu proje için teklif ayarları var"
        }
    }
    func refreshWorkflowRecommendation() {
        workflowRecommendationTask?.cancel()
        guard !project.pages.isEmpty else { workflowRecommendation = nil; return }
        var snapshot = project
        var automatic = snapshot.autoLayout ?? AutoLayoutSettings()
        automatic.sheetSelection = .automatic; automatic.manualFields.remove(.sheetSize); automatic.presetFields?.remove(.sheetSize)
        snapshot.autoLayout = automatic
        workflowRecommendationTask = Task { [snapshot] in
            try? await Task.sleep(for:.milliseconds(160))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority:.utility) { SmartAutoLayout.arrange(snapshot) }.value
            guard !Task.isCancelled else { return }
            if let sheet = result.plan.sheets.first,result.plan.canExport {
                workflowRecommendation = WorkflowSheetRecommendation(name:result.presetName,copies:sheet.repeatLayout?.copiesPerSheet ?? sheet.front.slots.count)
            } else { workflowRecommendation = nil }
        }
    }
    var workflowReadyText:String {
        guard project.hasPanelItems else {return source==nil ? "PDF seçin":"Baskıya dahil sayfa yok"}
        if source == nil { return "PDF seçerek başlayın" }
        if planning || autoArranging { return "Yerleşim hesaplanıyor…" }
        if exporting { return "PDF hazırlanıyor…" }
        return "Her şey hazır · \(plan.totalPressSheets) tabaka · \(currentSheet?.repeatLayout?.copiesPerSheet ?? currentSheet?.front.slots.count ?? 0) adet"
    }
}


extension Workspace {
    func revealWorkflowIssue(_ issue:ValidationIssue) {
        reveal(issue)
        if issue.code == .gangLayout { ui.jump(.montage) }
        else { ui.reveal(inspectorSection(for:issue)) }
        switch issue.code {
        case .missingBleed,.sharedCutBleed: ui.focusedArea = .bleed
        case .insufficientGutter: ui.focusedArea = .gutter
        case .exceedsSheet: ui.focusedArea = .margins
        default: break
        }
    }
    var workflowBleed:Double {
        get { selectedGangJob?.bleed ?? project.settings.bleed }
        set {
            let key = inspectorMemoryKey+(selectedGangJob?.id.uuidString ?? "global")
            let remembered = inspectorMemory.bleedOrigins[key]
            let original = remembered ?? (amount:workflowBleed,enabled:editableGeneratedBleed.enabled)
            if remembered == nil,newValue != original.amount { inspectorMemory.bleedOrigins[key] = original }
            let returning = remembered != nil && newValue == original.amount
            let enabled = returning ? original.enabled : true
            if let job = selectedGangJob { editGangJob(job.id) { $0.bleed = newValue; $0.generatedBleed.enabled = enabled } }
            else { project.settings.bleed = newValue; project.settings.generatedBleed.enabled = enabled }
            if returning { inspectorMemory.bleedOrigins.removeValue(forKey:key) }

        }
    }
}

extension Workspace {
    func showsBackInPreview(_ sheet: Sheet) -> Bool {
        sheet.hasContent(on: .back) ||
        (project.team?.duplex == true && (project.includeBlankBacks ?? true) && plan.hasBackContent)
    }

    var previewGeometry:SideScrollGeometry {
        SideScrollGeometry(heights:displaySheets.map { $0.size.height*PDFPreviewDrawing.pointsPerMM+110 },
                           repetitions:displaySheets.map { max(1,$0.repeatCount) },backs:displaySheets.map(showsBackInPreview))
    }
    var showsAllSides:Bool {
        get { project.allSheetsPreview ?? (previewGeometry.blockCount>1) }
        set { project.allSheetsPreview = newValue }
    }
    func selectPreviewLocation(_ location:PreviewSheetLocation) {
        if sheetIndex != location.sheet { sheetIndex = location.sheet }
        if repetition != location.repetition { repetition = location.repetition }
        if side != location.side { side = location.side }
    }
    func selectPreviewSheet(_ index:Int) {
        selectPreviewLocation(PreviewSheetLocation(sheet:index,repetition:0))
    }
    func movePreviewSheet(_ delta:Int) {
        let geometry = SheetScrollGeometry(heights:displaySheets.map { _ in 1 },repetitions:displaySheets.map { max(1,$0.repeatCount) })
        guard !geometry.heights.isEmpty else { return }
        var next = geometry.next(PreviewSheetLocation(sheet:sheetIndex,repetition:repetition),delta:delta)
        next.side = side
        selectPreviewLocation(next)
    }
    var previewSheetPosition:String {
        let geometry = previewGeometry
        guard geometry.heights.indices.contains(sheetIndex) else { return "Tabaka 0 / 0" }
        return "Tabaka \(geometry.firstNumbers[sheetIndex]+repetition+1) / \(geometry.repetitions.reduce(0,+))"
    }
}


extension Workspace {
    static let missingBleedWarning = "Bu işte taşma yok: kesimde beyaz kenar çıkabilir"
    var showsMissingBleedWarning: Bool {
        if project.binding == .gang {
            return (project.gang?.jobs ?? []).contains { job in
                !job.generatedBleed.enabled && [job.front,job.back].compactMap { $0 }.contains { ($0.availableBleed ?? 0) <= 0 }
            }
        }
        return !project.settings.generatedBleed.enabled && project.pages.contains { ($0.availableBleed ?? 0) <= 0 }
    }
    func enableMissingBleed() {
        if project.binding == .gang {
            for job in project.gang?.jobs ?? [] where [job.front,job.back].compactMap({ $0 }).contains(where: { ($0.availableBleed ?? 0) <= 0 }) {
                editGangJob(job.id) { $0.generatedBleed.enabled = true; if $0.bleed <= 0 { $0.bleed = 3 } }
            }
        } else {
            project.settings.generatedBleed.enabled = true
            if project.settings.bleed <= 0 { project.settings.bleed = 3 }
        }
    }
}


extension Workspace {
    func useLearnedSourceTrim(_ learned:PDFGuideAnalysis.Learned) {
        guard let input=preparationInput,canSplitSource else {return}
        pendingSourceTrim=(input.id,learned.trim,learned.bleed)
        showSplitAfterGuides=true;showingSourceGuides=false
    }
    var preparationSourceID:UUID { project.sourcePreparation?.sourceID ?? gangAssets.first?.saved.id ?? UUID() }
    var preparationInput:PDFSource? { source?.preparationInput }
    var canSeparateArtwork: Bool {
        preparationInput?.pages.count == 1 && gangAssets.count <= 1 && !project.isBooklet && !project.isLeafBinding
    }
    var canSplitSource:Bool { project.sourcePreparation?.separation == nil && preparationInput?.pages.count == 1 && gangAssets.count<=1 && !project.isBooklet && !project.isLeafBinding }
    var canInspectSourceGuides:Bool { preparationInput != nil && gangAssets.count<=1 }
    var suggestedPageSplit:PageSplitSettings? {
        guard canSplitSource,project.sourcePreparation?.hasPreparedProducts != true,project.sourcePreparation?.ignoreSplitSuggestion != true,let input=preparationInput else {return nil}
        return input.guides.suggestion(size:input.pages[0].trimSize)
    }
    var hiddenSourceGuideCount:Int {
        guard let input=preparationInput else {return 0}
        return input.guides.strokes.filter { project.sourcePreparation?.hiddenGuideGroups.contains($0.groupID) == true }.count
    }
    func dismissPageSplitSuggestion() {
        var settings=project.sourcePreparation ?? SourcePreparationSettings(sourceID:preparationSourceID)
        settings.ignoreSplitSuggestion=true;project.sourcePreparation=settings
    }
    func applySourcePreparation(_ settings:SourcePreparationSettings) async throws {
        guard let original=preparationInput,gangAssets.count<=1,!preparingSource else {throw SourcePreparationError.unsupportedSource}
        if settings.split != nil && settings.split != project.sourcePreparation?.split && !canSplitSource {throw SourcePreparationError.unsupportedSource}
        if settings.separation != nil && (!canSeparateArtwork || settings.split != nil) { throw SourcePreparationError.unsupportedSource }
        preparingSource=true;defer {preparingSource=false}
        let prepared=try await original.prepared(settings)
        try Task.checkCancellation()
        let reference=try ProjectSource.capture(original.originalURL,createBookmark:bookmarkCreator)
        var next=project;next.sourcePreparation=settings
        var assets=gangAssets
        let restoresSeparationMode = settings.separation.map {
            project.binding != .gang || $0.asTeam != (project.team != nil)
        } ?? false
        let changesGrid = settings.hasPreparedProducts && (settings.split != project.sourcePreparation?.split ||
                                                           settings.separation != project.sourcePreparation?.separation || restoresSeparationMode)
        if changesGrid {
            var gang=GangSettings()
            let products = settings.separation.map(PDFSourcePreparation.products) ??
                settings.split.map(PDFSourcePreparation.products) ?? []
            for product in products {
                let front=prepared.pages[product.front-1].sourcePage,back=product.back.map {prepared.pages[$0-1].sourcePage}
                var job=project.gang?.jobs.first(where:{$0.splitProduct==product.number}) ?? GangJob(sourceID:settings.sourceID,name:"Ürün \(product.number)",front:front,back:back)
                let existing=project.gang?.jobs.contains(where:{$0.id==job.id}) == true
                job.sourceID=settings.sourceID;job.splitProduct=product.number;job.front=front;job.back=back
                if !existing {
                    job.quantity=project.stepAndRepeat.quantity ?? 1000;job.bleed=([front]+[back].compactMap{$0}).compactMap(\.availableBleed).min() ?? settings.split?.cellBleed ?? 0
                    job.generatedBleed=project.settings.generatedBleed
                    job.generatedBleed.enabled=([front]+[back].compactMap{$0}).contains {($0.availableBleed ?? 0)+0.001<job.bleed}
                    job.serialFields=project.serialFields.map {var f=$0;f.id=UUID();f.jobIndex=0;return f}
                }
                if settings.separation != nil { job.rescale = nil }
                gang.jobs.append(job)
            }
            next.binding = .gang;next.gang=gang;next.book=nil;next.serialFields=[];next.scaling=nil;next.rescaleJobs=nil
            let hasPairedProducts = gang.jobs.contains { $0.back != nil }
            if settings.separation != nil {
                next.previouslyHadBacks = nil
                if !hasPairedProducts { next.settings.turnMethod = .sheetwise }
            }
            if settings.separation?.asTeam == true {
                var team = project.team ?? TeamSettings()
                if project.team == nil {
                    team.quantity = project.stepAndRepeat.quantity ?? 1000
                    team.waste = project.stepAndRepeat.waste ?? WasteSettings()
                }
                team.duplex = hasPairedProducts
                team.manualLayouts = nil
                next.team = team
            } else { next.team = nil }
            // Independent products start with space for both bleeds and protected crop ticks.
            if project.sourcePreparation?.hasPreparedProducts != true {
                let bleed = settings.separation == nil ? next.settings.bleed : gang.jobs.map(\.bleed).max() ?? 0
                next.sheet.gutter = max(2 * bleed, 2 * (next.settings.cropMarkOffset + next.settings.cropMarkLength))
            }
            assets=[GangAsset(saved:GangSourceReference(id:settings.sourceID,reference:reference,pageCount:original.pages.count),source:prepared)]
        } else if !assets.isEmpty {
            guard assets.count==1 else {throw SourcePreparationError.unsupportedSource}
            assets[0]=GangAsset(saved:GangSourceReference(id:assets[0].saved.id,reference:reference,pageCount:original.pages.count),source:prepared)
        }
        if changesGrid {next.pages=prepared.pages.map(\.sourcePage);next.pageItems=nil;next.pageItemNextID=nil}
        else if let items=project.pageItems {
            next.pageItems=try items.map {item in
                var next=item
                if let number=item.sourcePage {
                    guard prepared.pages.indices.contains(number-1) else {throw ProjectFileError.sourceMismatch}
                    next.size=prepared.pages[number-1].trimSize;next.availableBleed=prepared.pages[number-1].availableBleed
                }
                return next
            }
            let map=Dictionary(uniqueKeysWithValues:next.pageItems!.map{($0.id,$0)})
            next.pages=order.filter{included.contains($0)}.compactMap{map[$0]?.planningPage}
        } else {
            guard project.pages.allSatisfy({prepared.pages.indices.contains($0.number-1)}) else {throw ProjectFileError.sourceMismatch}
            next.pages=project.pages.map{prepared.pages[$0.number-1].sourcePage}
        }
        let selectedJob=selectedGangJobID
        beginUndoGroup();restoring=true
        source=prepared;gangAssets=assets;sourceReference=assets.isEmpty ? reference:nil
        if changesGrid {order=next.pages.map(\.number);included=Set(order);selectedPages=[];sheetIndex=0;repetition=0}
        project=next
        selectedGangJobID=next.gang?.jobs.first(where:{$0.id==selectedJob})?.id ?? next.gang?.jobs.first?.id
        restoring=false;refreshModified();schedulePlan();endUndoGroup()
    }
}
