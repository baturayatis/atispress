import SwiftUI
import ImpositionCore
import PDFEngine

/// Fixed row geometry makes selection and virtualization independent of page count.
struct PreviewSheetLocation: Hashable {
    var sheet: Int
    var repetition: Int
    var side: SideKind = .front
}
struct SheetScrollGeometry {
    var heights: [CGFloat]
    let starts: [CGFloat]
    let repetitions: [Int]
    let firstNumbers: [Int]
    var totalHeight: CGFloat { guard let last = heights.indices.last else { return 0 }; return starts[last]+heights[last]*CGFloat(repetitions[last]) }
    init(heights:[CGFloat],repetitions:[Int]? = nil) {
        self.heights = heights
        let counts = repetitions ?? Array(repeating:1,count:heights.count)
        self.repetitions = counts
        var y: CGFloat = 0,number = 0
        starts = heights.indices.map { i in defer { y += heights[i]*CGFloat(counts[i]) }; return y }
        firstNumbers = counts.map { count in defer { number += count }; return number }
    }
    func index(at y: CGFloat) -> Int {
        let positions = starts
        guard !positions.isEmpty else { return 0 }
        var lo = 0, hi = positions.count
        while lo < hi { let mid = (lo+hi)/2; if positions[mid] <= y { lo = mid+1 } else { hi = mid } }
        return max(0,lo-1)
    }
    func location(at y:CGFloat) -> PreviewSheetLocation {
        let i = index(at:y)
        guard heights.indices.contains(i) else { return PreviewSheetLocation(sheet:0,repetition:0) }
        let repeatIndex = Int(min(CGFloat(repetitions[i]-1),max(0,(y-starts[i])/heights[i])))
        return PreviewSheetLocation(sheet:i,repetition:repeatIndex)
    }
    func origin(_ location:PreviewSheetLocation) -> CGFloat { starts[location.sheet]+CGFloat(location.repetition)*heights[location.sheet] }
    func next(_ location:PreviewSheetLocation,delta:Int) -> PreviewSheetLocation {
        var i = location.sheet,r = location.repetition+delta
        if r<0 { if i>0 { i -= 1; r = repetitions[i]-1 } else { r = 0 } }
        if r>=repetitions[i] { if i+1<heights.count { i += 1; r = 0 } else { r = repetitions[i]-1 } }
        return PreviewSheetLocation(sheet:i,repetition:r)
    }
    func moved(_ index: Int,by delta: Int) -> Int { min(max(0,heights.count-1),max(0,index+delta)) }
}

/// Compact prefixes: memory depends on plan sheets, never on repeated copies.
struct SideScrollGeometry {
    let heights:[CGFloat]
    let backs:[Bool]
    private let groups:SheetScrollGeometry
    var starts:[CGFloat] { groups.starts }
    var repetitions:[Int] { groups.repetitions }
    var firstNumbers:[Int] { groups.firstNumbers }
    var totalHeight:CGFloat { groups.totalHeight }
    var blockCount:Int { heights.indices.reduce(0) { $0 + repetitions[$1]*(backs[$1] ? 2 : 1) } }
    init(heights:[CGFloat],repetitions:[Int],backs:[Bool]) {
        self.heights = heights; self.backs = backs
        groups = SheetScrollGeometry(heights:heights.indices.map { heights[$0]*(backs[$0] ? 2 : 1) },repetitions:repetitions)
    }
    func location(at y:CGFloat) -> PreviewSheetLocation {
        var location = groups.location(at:y)
        guard heights.indices.contains(location.sheet) else { return location }
        let offset = y-groups.origin(location)
        if backs[location.sheet],offset >= heights[location.sheet] { location.side = .back }
        return location
    }
    func origin(_ location:PreviewSheetLocation) -> CGFloat {
        groups.origin(location)+(location.side == .back && backs[location.sheet] ? heights[location.sheet] : 0)
    }
    func next(_ location:PreviewSheetLocation,delta:Int) -> PreviewSheetLocation {
        if delta>0,location.side == .front,backs[location.sheet] {
            return PreviewSheetLocation(sheet:location.sheet,repetition:location.repetition,side:.back)
        }
        if delta<0,location.side == .back { return PreviewSheetLocation(sheet:location.sheet,repetition:location.repetition) }
        var next = groups.next(PreviewSheetLocation(sheet:location.sheet,repetition:location.repetition),delta:delta)
        if next.sheet == location.sheet,next.repetition == location.repetition { return location }
        if delta<0,backs[next.sheet] { next.side = .back }
        return next
    }
}

struct AllSheetsPreview: NSViewRepresentable {
    @ObservedObject var model: Workspace
    func makeNSView(context: Context) -> AllSheetsScrollView {
        let scroll = AllSheetsScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.backgroundColor = DesignSystem.workspaceNS
        scroll.allowsMagnification = true; scroll.minMagnification = 0.04; scroll.maxMagnification = 12
        let document = AllSheetsDocument(); scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(scroll,selector: #selector(AllSheetsScrollView.didScroll),name: NSView.boundsDidChangeNotification,object: scroll.contentView)
        updateNSView(scroll,context: context)
        return scroll
    }
    func updateNSView(_ scroll: AllSheetsScrollView,context: Context) {
        guard let document = scroll.documentView as? AllSheetsDocument else { return }
        scroll.suppressReporting = true
        defer { scroll.suppressReporting = false }
        document.model = model; let geometryChanged = document.updateGeometry()
        let requested = PreviewSheetLocation(sheet:model.sheetIndex,repetition:model.repetition,side:model.side)
        if scroll.lastModelLocation != requested {
            scroll.selectionRevision += 1; scroll.pendingLocation = nil
        }
        scroll.lastModelLocation = requested
        scroll.locationChanged = { [weak model,weak scroll] location in
            guard let model else { return }
            scroll?.queueSelection(location,model:model)
        }
        if scroll.zoomAction != model.zoomAction {
            let firstPresentation = scroll.zoomAction < 0
            scroll.zoomAction = model.zoomAction
            // zoomAction is an event counter, not a stored absolute magnification.
            // Replaying the last zoom before AppKit has a viewport loses the selected face.
            if firstPresentation { scroll.fitRequested = true; scroll.needsLayout = true }
            else if model.zoomFactor == 0 { scroll.fitRequested = true; scroll.needsLayout = true }
            else { scroll.setMagnification(min(12,max(0.04,scroll.magnification*model.zoomFactor)),centeredAt:scroll.documentVisibleRect.origin) }
        }
        document.updateViewportExtent()
        if scroll.pendingLocation == nil { scroll.revealSelection(requested,force:geometryChanged) }
        document.refreshVisible()
    }
}

final class AllSheetsScrollView: NSScrollView {
    var fitRequested = true
    var zoomAction = -1
    var reportedSelection = -1
    var reportedRepetition = 0
    var lastModelLocation:PreviewSheetLocation?
    var pendingLocation:PreviewSheetLocation?
    var selectionRevision = 0
    var suppressReporting = false
    var reportedSide:SideKind = .front
    var locationChanged:((PreviewSheetLocation)->Void)?
    var selectionChanged: ((Int,Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc func didScroll() {
        guard let document = documentView as? AllSheetsDocument else { return }
        document.refreshVisible()
        guard !suppressReporting else { return }
        let location = document.geometry.location(at:documentVisibleRect.minY+1)
        if location.sheet != reportedSelection || location.repetition != reportedRepetition || location.side != reportedSide {
            reportedSelection = location.sheet; reportedRepetition = location.repetition; reportedSide = location.side; locationChanged?(location); selectionChanged?(location.sheet,location.repetition)
        }
    }
    func queueSelection(_ location:PreviewSheetLocation,model:Workspace) {
        selectionRevision += 1
        let revision = selectionRevision
        pendingLocation = location
        DispatchQueue.main.async { [weak self,weak model] in
            guard let self,let model,self.selectionRevision == revision else { return }
            self.pendingLocation = nil
            let current = PreviewSheetLocation(sheet:model.sheetIndex,repetition:model.repetition,side:model.side)
            // A later segment/list click wins over an already queued scroll event.
            guard self.lastModelLocation == nil || current == self.lastModelLocation else { return }
            model.selectPreviewLocation(location)
        }
    }
    func revealSelection(_ location:PreviewSheetLocation,force:Bool = false) {
        guard let document = documentView as? AllSheetsDocument,document.geometry.heights.indices.contains(location.sheet) else { return }
        guard force || reportedSelection != location.sheet || reportedRepetition != location.repetition || reportedSide != location.side else { return }
        reportedSelection = location.sheet; reportedRepetition = location.repetition; reportedSide = location.side
        var target = location
        target.repetition = min(max(0,target.repetition),document.geometry.repetitions[target.sheet]-1)
        let previous = suppressReporting; suppressReporting = true
        document.scroll(NSPoint(x:0,y:document.geometry.origin(target)))
        suppressReporting = previous
        document.refreshVisible()
    }
    func scrollToSheet(_ index:Int,repetition:Int = 0,side:SideKind = .front) {
        guard let document = documentView as? AllSheetsDocument,document.geometry.heights.indices.contains(index) else { return }
        document.scroll(NSPoint(x:0,y:document.geometry.origin(PreviewSheetLocation(sheet:index,repetition:repetition,side:side)))); didScroll()
    }
    override func keyDown(with event: NSEvent) {
        let delta: Int
        switch event.keyCode { case 116,123,126: delta = -1; case 121,124,125: delta = 1; default: super.keyDown(with:event); return }
        guard let document = documentView as? AllSheetsDocument,!document.geometry.heights.isEmpty else { return }
        let location = document.geometry.next(PreviewSheetLocation(sheet:max(0,reportedSelection),repetition:reportedRepetition,side:reportedSide),delta:delta)
        scrollToSheet(location.sheet,repetition:location.repetition,side:location.side)
    }
    override func scrollWheel(with event:NSEvent) {
        if event.modifierFlags.contains(.command) {
            setMagnification(min(maxMagnification,max(minMagnification,magnification*exp(-event.scrollingDeltaY*0.01))),centeredAt:documentVisibleRect.origin)
            (documentView as? AllSheetsDocument)?.updateViewportExtent()
        } else { super.scrollWheel(with:event) }
    }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with:event) }
    override func layout() {
        super.layout()
        if fitRequested,contentSize.width>100,let document = documentView,document.frame.width>0 {
            fitRequested = false
            let target = PreviewSheetLocation(sheet:max(0,reportedSelection),repetition:reportedRepetition,side:reportedSide)
            let previous = suppressReporting; suppressReporting = true
            setMagnification(min(12,max(0.04,contentSize.width/document.frame.width*0.98)),centeredAt:documentVisibleRect.origin)
            (document as? AllSheetsDocument)?.updateViewportExtent()
            revealSelection(target,force:true)
            suppressReporting = previous
        }
        (documentView as? AllSheetsDocument)?.updateViewportExtent()
        (documentView as? AllSheetsDocument)?.refreshVisible()
    }
}

final class AllSheetsDocument: NSView {
    weak var model: Workspace?
    var geometry = SideScrollGeometry(heights:[],repetitions:[],backs:[])
    private var rows: [PreviewSheetLocation:NSView] = [:]
    private var lastSheets: [Sheet] = []
    private var lastFocus:WorkflowFocus?
    private var lastOptions: PDFRenderOptions?
    private var lastMarks: ExportMarks?
    private weak var lastSource: PDFSource?
    override var isFlipped: Bool { true }
    @discardableResult func updateGeometry() -> Bool {
        guard let model else { return false }
        guard lastSheets != model.displaySheets || lastOptions != model.overlays || lastMarks != model.project.exportMarks || lastSource !== model.source || lastFocus != model.ui.focusedArea else { return false }
        lastFocus = model.ui.focusedArea
        lastSheets = model.displaySheets; lastOptions = model.overlays; lastMarks = model.project.exportMarks; lastSource = model.source
        geometry = SideScrollGeometry(heights: model.displaySheets.map { $0.size.height*PDFPreviewDrawing.pointsPerMM+110 },repetitions:model.displaySheets.map { max(1,$0.repeatCount) },backs:model.displaySheets.map { $0.hasContent(on:.back) })
        let width = (model.displaySheets.map { $0.size.width*PDFPreviewDrawing.pointsPerMM+64 }.max() ?? 500)
        setFrameSize(NSSize(width:width,height:geometry.totalHeight))
        // Only the visible rows carry PDF documents, canvases and edge caches.
        rows.values.forEach { $0.removeFromSuperview() }; rows.removeAll()
        return true
    }
    /// Permit the last sheet to align at the top even when zoomed to less
    /// than a viewport; otherwise AppKit clamps and selects its predecessor.
    func updateViewportExtent() {
        guard let scroll = enclosingScrollView,let last = geometry.heights.indices.last else { return }
        let location = PreviewSheetLocation(sheet:last,repetition:geometry.repetitions[last]-1,side:geometry.backs[last] ? .back : .front)
        let height = max(geometry.totalHeight,geometry.origin(location)+scroll.contentSize.height/scroll.magnification)
        if abs(frame.height-height)>0.5 { setFrameSize(NSSize(width:frame.width,height:height)) }
    }
    func refreshVisible() {
        guard let model,!geometry.heights.isEmpty else { return }
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        var location = geometry.location(at:visible.minY)
        var wanted = Set<PreviewSheetLocation>()
        repeat {
            wanted.insert(location)
            let next = geometry.next(location,delta:1)
            if next == location || geometry.origin(next)>visible.maxY { break }
            location = next
        } while true
        for index in Array(rows.keys) where !wanted.contains(index) { rows.removeValue(forKey:index)?.removeFromSuperview() }
        for location in wanted where rows[location] == nil {
            let index = location.sheet
            let sheet = model.displaySheets[index]
            let row = NSView(frame:NSRect(x:0,y:geometry.origin(location),width:frame.width,height:geometry.heights[index]))
            let label = NSTextField(labelWithString:(["Tabaka \(geometry.firstNumbers[index]+location.repetition+1) · \(location.side == .front ? "Ön yüz" : "Arka yüz")" + (geometry.backs[index] ? "" : " · Arka yüz yok")]+sheet.serialRangeLabels+[sheet.front.slots.compactMap(\.rescale).first?.summary].compactMap { $0 }).joined(separator:" · "))
            label.font = .systemFont(ofSize:20,weight:.medium)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x:20,y:row.frame.height-46,width:frame.width-40,height:44); row.addSubview(label)
            do {
                let kind = location.side
                let canvas = SheetCanvasView()
                canvas.focusArea = model.ui.focusedArea
                canvas.repetition = location.repetition
                canvas.configure(sheet:sheet,side:kind == .front ? sheet.front : sheet.back,source:model.source,overlays:model.overlays,highlighted:[],sheetIndex:index,kind:kind,generatedBleed:model.plan.generatedBleed,controlMarks:model.project.exportMarks)
                canvas.setFrameOrigin(NSPoint(x:0,y:0))
                row.addSubview(canvas)
            }
            rows[location] = row; addSubview(row)
        }
    }
}
