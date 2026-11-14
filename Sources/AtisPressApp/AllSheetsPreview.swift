import SwiftUI
import ImpositionCore
import PDFEngine

/// Fixed row geometry makes selection and virtualization independent of page count.
struct PreviewSheetLocation: Hashable {
    var sheet: Int
    var repetition: Int
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
        return PreviewSheetLocation(sheet:i,repetition:min(repetitions[i]-1,max(0,Int((y-starts[i])/heights[i]))))
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

struct AllSheetsPreview: NSViewRepresentable {
    @ObservedObject var model: Workspace
    func makeNSView(context: Context) -> AllSheetsScrollView {
        let scroll = AllSheetsScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.04; scroll.maxMagnification = 12
        let document = AllSheetsDocument(); scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(scroll,selector: #selector(AllSheetsScrollView.didScroll),name: NSView.boundsDidChangeNotification,object: scroll.contentView)
        updateNSView(scroll,context: context)
        return scroll
    }
    func updateNSView(_ scroll: AllSheetsScrollView,context: Context) {
        guard let document = scroll.documentView as? AllSheetsDocument else { return }
        document.model = model; document.updateGeometry()
        scroll.selectionChanged = { [weak model] index,repetition in
            guard let model,model.sheetIndex != index || model.repetition != repetition else { return }
            DispatchQueue.main.async { model.sheetIndex = index; model.repetition = repetition }
        }
        if scroll.zoomAction != model.zoomAction {
            scroll.zoomAction = model.zoomAction
            if model.zoomFactor == 0 { scroll.fitRequested = true; scroll.needsLayout = true }
            else { scroll.setMagnification(min(12,max(0.04,scroll.magnification*model.zoomFactor)),centeredAt:scroll.documentVisibleRect.origin) }
        }
        document.updateViewportExtent()
        if scroll.reportedSelection != model.sheetIndex || scroll.reportedRepetition != model.repetition {
            scroll.reportedSelection = model.sheetIndex; scroll.reportedRepetition = model.repetition
            if document.geometry.heights.indices.contains(model.sheetIndex) {
                document.scroll(NSPoint(x:0,y:document.geometry.origin(PreviewSheetLocation(sheet:model.sheetIndex,repetition:min(model.repetition,document.geometry.repetitions[model.sheetIndex]-1)))))
            }
        }
        document.refreshVisible()
    }
}

final class AllSheetsScrollView: NSScrollView {
    var fitRequested = true
    var zoomAction = -1
    var reportedSelection = -1
    var reportedRepetition = 0
    var selectionChanged: ((Int,Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc func didScroll() {
        guard let document = documentView as? AllSheetsDocument else { return }
        document.refreshVisible()
        let location = document.geometry.location(at:documentVisibleRect.minY+1)
        if location.sheet != reportedSelection || location.repetition != reportedRepetition {
            reportedSelection = location.sheet; reportedRepetition = location.repetition; selectionChanged?(location.sheet,location.repetition)
        }
    }
    func scrollToSheet(_ index:Int,repetition:Int = 0) {
        guard let document = documentView as? AllSheetsDocument,document.geometry.heights.indices.contains(index) else { return }
        document.scroll(NSPoint(x:0,y:document.geometry.origin(PreviewSheetLocation(sheet:index,repetition:repetition)))); didScroll()
    }
    override func keyDown(with event: NSEvent) {
        let delta: Int
        switch event.keyCode { case 116,123,126: delta = -1; case 121,124,125: delta = 1; default: super.keyDown(with:event); return }
        guard let document = documentView as? AllSheetsDocument,!document.geometry.heights.isEmpty else { return }
        let location = document.geometry.next(PreviewSheetLocation(sheet:max(0,reportedSelection),repetition:reportedRepetition),delta:delta)
        scrollToSheet(location.sheet,repetition:location.repetition)
    }
    override func layout() {
        super.layout()
        if fitRequested,contentSize.width>100,let document = documentView,document.frame.width>0 {
            fitRequested = false
            setMagnification(min(12,max(0.04,contentSize.width/document.frame.width*0.98)),centeredAt:documentVisibleRect.origin)
        }
        (documentView as? AllSheetsDocument)?.updateViewportExtent()
        (documentView as? AllSheetsDocument)?.refreshVisible()
    }
}

final class AllSheetsDocument: NSView {
    weak var model: Workspace?
    var geometry = SheetScrollGeometry(heights: [])
    private var rows: [PreviewSheetLocation:NSView] = [:]
    private var lastSheets: [Sheet] = []
    private var lastFocus:WorkflowFocus?
    private var lastOptions: PDFRenderOptions?
    private var lastMarks: ExportMarks?
    private weak var lastSource: PDFSource?
    override var isFlipped: Bool { true }
    func updateGeometry() {
        guard let model else { return }
        guard lastSheets != model.displaySheets || lastOptions != model.overlays || lastMarks != model.project.exportMarks || lastSource !== model.source || lastFocus != model.ui.focusedArea else { return }
        lastFocus = model.ui.focusedArea
        lastSheets = model.displaySheets; lastOptions = model.overlays; lastMarks = model.project.exportMarks; lastSource = model.source
        geometry = SheetScrollGeometry(heights: model.displaySheets.map { $0.size.height*PDFPreviewDrawing.pointsPerMM+110 },repetitions:model.displaySheets.map { max(1,$0.repeatCount) })
        let width = (model.displaySheets.map { $0.size.width*PDFPreviewDrawing.pointsPerMM+64 }.max() ?? 500)*2
        setFrameSize(NSSize(width:width,height:geometry.totalHeight))
        // Only the visible rows carry PDF documents, canvases and edge caches.
        rows.values.forEach { $0.removeFromSuperview() }; rows.removeAll()
    }
    /// Permit the last sheet to align at the top even when zoomed to less
    /// than a viewport; otherwise AppKit clamps and selects its predecessor.
    func updateViewportExtent() {
        guard let scroll = enclosingScrollView,let last = geometry.heights.indices.last else { return }
        let location = PreviewSheetLocation(sheet:last,repetition:geometry.repetitions[last]-1)
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
            let label = NSTextField(labelWithString:(["Tabaka \(geometry.firstNumbers[index]+location.repetition+1) · Ön / Arka"]+sheet.serialRangeLabels+[sheet.front.slots.compactMap(\.rescale).first?.summary].compactMap { $0 }).joined(separator:" · "))
            label.font = .systemFont(ofSize:36,weight:.medium)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x:20,y:row.frame.height-46,width:frame.width-40,height:44); row.addSubview(label)
            for (column,kind) in [SideKind.front,.back].enumerated() {
                let canvas = SheetCanvasView()
                canvas.focusArea = model.ui.focusedArea
                canvas.repetition = location.repetition
                canvas.configure(sheet:sheet,side:kind == .front ? sheet.front : sheet.back,source:model.source,overlays:model.overlays,highlighted:[],sheetIndex:index,kind:kind,generatedBleed:model.plan.generatedBleed,controlMarks:model.project.exportMarks)
                canvas.setFrameOrigin(NSPoint(x:CGFloat(column)*frame.width/2,y:0))
                row.addSubview(canvas)
            }
            rows[location] = row; addSubview(row)
        }
    }
}
