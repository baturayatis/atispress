import SwiftUI
import PDFEngine
import ImpositionCore

struct PreviewCanvas: NSViewRepresentable {
    let sheet: Sheet
    let side: Side
    let sheetIndex: Int
    let sideKind: SideKind
    let source: PDFSource?
    let overlays: PreviewOverlays
    var printedInfo: String = ""
    let generatedBleed: GeneratedBleedSettings
    var bleedAmount: Double = 3
    let highlighted: Set<Int>
    let zoomAction: Int
    let zoomFactor: CGFloat
    var zoomModel:Workspace? = nil
    var focusArea:WorkflowFocus? = nil
    var moveSheet:((Int)->Void)? = nil
    var repetition: Int = 0
    var selectedSerial: UUID? = nil
    var selectSerial: ((UUID) -> Void)? = nil
    var moveSerial: ((UUID,Point) -> Void)? = nil
    var controlMarks = ExportMarks.none
    var moveGangBlock: ((UUID,Point) -> Void)? = nil
    var beginEdit: (() -> Void)? = nil
    var endEdit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PreviewScrollView()
        scroll.moveSheet = moveSheet
        scroll.contentView = CenteredClipView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.allowsMagnification = true
        scroll.minMagnification = 0.001; scroll.maxMagnification = 12
        scroll.backgroundColor = DesignSystem.workspaceNS
        let canvas = SheetCanvasView()
        scroll.documentView = canvas
        update(canvas)
        if let model = zoomModel { scroll.synchronizeZoom(model) }
        scroll.requestFit()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView,context: Context) {
        (scroll as? PreviewScrollView)?.moveSheet = moveSheet
        guard let canvas = scroll.documentView as? SheetCanvasView else { return }
        let sizeChanged = canvas.sheet?.size != sheet.size || canvas.sheet?.diagnosticBounds != sheet.diagnosticBounds
        update(canvas)
        if let model = zoomModel { (scroll as? PreviewScrollView)?.synchronizeZoom(model) }
        else if canvas.zoomAction != zoomAction {
            canvas.zoomAction = zoomAction
            if zoomFactor == 0 { (scroll as? PreviewScrollView)?.autoFitEnabled = true; (scroll as? PreviewScrollView)?.requestFit() }
            else { (scroll as? PreviewScrollView)?.manualZoom(by:zoomFactor) }
        }
        if sizeChanged { (scroll as? PreviewScrollView)?.requestFit() }

    }
    private func update(_ canvas: SheetCanvasView) {
        if let zoomModel { canvas.connectSerialEditing(zoomModel) }
        canvas.focusArea = focusArea
        canvas.repetition = repetition; canvas.selectedSerial = selectedSerial
        canvas.selectSerial = selectSerial; canvas.moveSerial = moveSerial; canvas.moveGangBlock = moveGangBlock; canvas.beginEdit = beginEdit; canvas.endEdit = endEdit
        canvas.configure(sheet: sheet,side: side,source: source,overlays: overlays,highlighted: highlighted,sheetIndex: sheetIndex,kind: sideKind,generatedBleed: generatedBleed,controlMarks: controlMarks,bleedAmount:bleedAmount,info:printedInfo)
    }
}

final class PreviewScrollView:AutoFitScrollView {
    var moveSheet:((Int)->Void)?
    override var acceptsFirstResponder:Bool { true }
    override func keyDown(with event:NSEvent) {
        switch event.keyCode { case 123: moveSheet?(-1); case 124: moveSheet?(1); default: super.keyDown(with:event) }
    }
}
private final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView {
            if document.frame.width < rect.width { rect.origin.x = (document.frame.width-rect.width)/2 }
            if document.frame.height < rect.height { rect.origin.y = (document.frame.height-rect.height)/2 }
        }
        return rect
    }
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX,y: midY) } }

/// All rectangles, transforms, lines and page identities come from the supplied plan.
/// AppKit handles scrolling; PDFKit rasters are used at low zoom and Quartz draws vectors at high zoom.
final class SheetCanvasView: NSView {
    var focusArea:WorkflowFocus?
    var sheet: Sheet?
    var side = Side()
    var source: PDFSource?
    var overlays = PreviewOverlays()
    var bleedGuideEnabled = false
    var printedMarks = ExportMarks.none
    var printedInfo = ""
    var highlighted = Set<Int>()
    var zoomAction = 0
    var sheetIndex = 0
    var sideKind: SideKind = .front
    var slotOverlays: [any PDFSlotOverlay] = []
    var repetition = 0
    var selectedSerial: UUID?
    var selectSerial: ((UUID) -> Void)?
    var moveSerial: ((UUID,Point) -> Void)?
    var moveGangBlock: ((UUID,Point) -> Void)?
    var beginEdit: (() -> Void)?
    var endEdit: (() -> Void)?
    private var gangDrag: (id: UUID,origin: Point,start: CGPoint,flipX: Bool,flipY: Bool)?
    private var originX: CGFloat = 32
    private var originY: CGFloat = 32
    private var serialDrag: (slot: Slot,id: UUID,offset: CGPoint,start:Point)?
    private(set) var dragPosition:Point?
    var serialPosition:((UUID)->Point?)?
    private var colorControls: PDFColorControlRenderer.Geometry?
    private var generatedOverlay: GeneratedBleedOverlay?
    private var vectorDocument: CGPDFDocument?
    private var loading = Set<Int>()
    private var failedRasters = Set<Int>()
    private var dragPoint: CGPoint?
    private let pointsPerMM: CGFloat = 72/25.4
    private let padding: CGFloat = 32

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self,selector: #selector(magnificationEnded),
            name: NSScrollView.didEndLiveMagnifyNotification,object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func magnificationEnded() { needsDisplay = true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func configure(sheet: Sheet,side: Side,source: PDFSource?,overlays: PreviewOverlays,highlighted: Set<Int>,sheetIndex: Int = 0,kind: SideKind = .front,generatedBleed: GeneratedBleedSettings = GeneratedBleedSettings(),controlMarks: ExportMarks = .none,bleedAmount: Double = 3,info:String = "") {
        if self.source !== source {
            self.source = source; loading = []; failedRasters = []
            vectorDocument = source.flatMap { CGPDFDocument($0.url as CFURL) }
        }
        generatedOverlay = (generatedBleed.enabled || sheet.generatedBleedByJob.values.contains { $0.enabled }) ? source.map { GeneratedBleedOverlay(settings: generatedBleed,cache: $0.edgeSamples,jobSettings: sheet.generatedBleedByJob) } : nil
        printedInfo = info
        printedMarks = controlMarks
        var previewMarks = controlMarks
        previewMarks.colorBar = overlays.colorBar; previewMarks.registrationTargets = overlays.registrationTargets
        colorControls = overlays.colorBar || overlays.registrationTargets ? PDFColorControlRenderer.geometry(sheet: sheet,settings: previewMarks,kind: kind) : nil
        bleedGuideEnabled = bleedAmount > 0 && (generatedBleed.enabled || side.slots.contains { slot in
            guard let number = slot.sourcePageNumber, let source, source.pages.indices.contains(number-1) else { return false }
            return (source.pages[number-1].availableBleed ?? 0)+0.001 >= bleedAmount
        })
        self.sheetIndex = sheetIndex; self.sideKind = kind
        self.sheet = sheet; self.side = side; self.overlays = overlays; self.highlighted = highlighted
        originX = padding+max(0,-(side.slots.map(\.x).min() ?? 0))*pointsPerMM
        originY = padding+max(0,-(side.slots.map(\.y).min() ?? 0))*pointsPerMM
        let width = max(sheet.size.width,(sheet.diagnosticBounds?.origin.x ?? 0)+(sheet.diagnosticBounds?.size.width ?? 0))
        let height = max(sheet.size.height,(sheet.diagnosticBounds?.origin.y ?? 0)+(sheet.diagnosticBounds?.size.height ?? 0))
        let farX = max(width,side.slots.map { $0.x+$0.size.width }.max() ?? width),farY = max(height,side.slots.map { $0.y+$0.size.height }.max() ?? height)
        let newSize = NSSize(width: farX*pointsPerMM+originX+padding,height: farY*pointsPerMM+originY+padding)
        if frame.size != newSize { setFrameSize(newSize) }
        needsDisplay = true
    }
    func fit() {
        guard let scroll = enclosingScrollView as? AutoFitScrollView else { return }
        scroll.autoFitEnabled = true; scroll.requestFit(); scroll.layoutSubtreeIfNeeded()
    }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); needsDisplay = true }
    override func magnify(with event: NSEvent) { super.magnify(with: event); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        DesignSystem.workspaceNS.setFill(); bounds.fill()
        guard let sheet, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: originX,y: originY); context.scaleBy(x: pointsPerMM,y: pointsPerMM)
        let paper = CGRect(x: 0,y: 0,width: sheet.size.width,height: sheet.size.height)
        context.saveGState()
        context.setShadow(offset:CGSize(width:0,height:-1),blur:3,color:DesignSystem.shadowNS.cgColor)
        context.setFillColor(DesignSystem.paperNS.cgColor); context.fill(paper)
        context.restoreGState()
        if sheet.gangLayout == nil { context.clip(to: paper) }
        let scale = max(0.01,enclosingScrollView?.magnification ?? 1)
        let visible = visibleRect.insetBy(dx: -40,dy: -40)
        let serials: [any PDFSlotOverlay] = [GangSerialOverlay(sheet: sheet)]
        let extensions: [any PDFSlotOverlay] = (generatedOverlay.map { [$0 as any PDFSlotOverlay] } ?? [])+slotOverlays+serials
        for (index,slot) in side.slots.enumerated() {
            let rect = CGRect(x: slot.x,y: slot.y,width: slot.size.width,height: slot.size.height)
            let extent = slot.artworkClip.map { CGRect(x: $0.origin.x,y: $0.origin.y,width: $0.size.width,height: $0.size.height) } ?? rect
            let viewRect = CGRect(x: extent.minX*pointsPerMM+originX,y: extent.minY*pointsPerMM+originY,
                                  width: extent.width*pointsPerMM,height: extent.height*pointsPerMM)
            guard visible.intersects(viewRect) else { continue }
            let projectedPixels = max(viewRect.width,viewRect.height)*scale*(window?.backingScaleFactor ?? 2)
            let rasterPixels = projectedPixels <= 128 ? 128 : projectedPixels <= 256 ? 256 : 512
            context.saveGState()
            context.setFillColor(DesignSystem.paperNS.cgColor); context.fill(rect)
            if let number = slot.sourcePageNumber {
                let page = vectorDocument?.page(at: number)
                let raster = scale < 0.85 && slot.rescale == nil ? source?.cachedRaster(page: number,pixels: rasterPixels) : nil
                if scale < 0.85 && slot.rescale == nil && raster == nil && !failedRasters.contains(number) { loadRaster(number,pixels: rasterPixels) }
                // A vector fallback avoids flashing empty trim rectangles while the bleed raster loads.
                try? PDFPlanRenderer.drawSlot(slot,page: page,in: context,
                    reference: SlotReference(sheet: sheetIndex,side: sideKind,slot: index),repetition: repetition,raster: raster,overlays: extensions)
            } else {
                context.setFillColor((slot.bookRegion == nil ? DesignSystem.blankNS : DesignSystem.paperNS).cgColor); context.fill(rect)
                if slot.bookRegion == nil {
                    context.setStrokeColor(DesignSystem.guideNS.cgColor); context.setLineWidth(0.35)
                    context.move(to: rect.origin); context.addLine(to: CGPoint(x: rect.maxX,y: rect.maxY))
                    context.move(to: CGPoint(x: rect.minX,y: rect.maxY)); context.addLine(to: CGPoint(x: rect.maxX,y: rect.minY)); context.strokePath()
                }
                try? PDFPlanRenderer.drawSlot(slot,page: nil,in: context,
                    reference: SlotReference(sheet: sheetIndex,side: sideKind,slot: index),repetition: repetition,overlays: extensions)
            }
            context.restoreGState()
            if let id = slot.gangJobID,let job = sheet.gangLayout?.jobs.first(where: { $0.job.id==id })?.job {
                context.setFillColor(DesignSystem.jobTint(job.tint,fill:true).cgColor); context.fill(rect)
                if overlays.pageNumbers {
                    let text = sheet.gangLayout?.isTeam == true
                        ? slot.sourcePageNumber.map { "Sayfa \($0)" } ?? "Boş"
                        : job.name
                    label(text,at:CGPoint(x:rect.midX,y:rect.maxY-3),size:2.5,color:DesignSystem.jobTint(job.tint,fill:false))
                }
            }
            context.setStrokeColor((highlighted.contains(index) ? DesignSystem.errorNS : DesignSystem.guideNS).cgColor)
            context.setLineWidth((highlighted.contains(index) ? 2.5 : 0.5)/pointsPerMM/scale)
            if overlays.crop || highlighted.contains(index) { context.stroke(rect) }
            if overlays.pageNumbers && (slot.rotation != 0 || slot.mirrored || slot.sourcePageNumber == nil) {
                let text = slot.bookRegion ?? (slot.sourcePageNumber == nil ? "BOŞ" : [slot.rotation != 0 ? "↻ \(slot.rotation)°" : nil,slot.mirrored ? "AYNALI" : nil].compactMap{$0}.joined(separator: " · "))
                label(text,at: CGPoint(x: rect.midX,y: rect.minY+min(5,rect.height/5)),size: 3,color:DesignSystem.purpleNS)
            }
        }
        if let selectedSerial {
            context.setStrokeColor(DesignSystem.focusNS.cgColor); context.setLineWidth(1/pointsPerMM/scale)
            for serial in sheet.serialPlacements(side: side,kind: sideKind,repetition: repetition) where serial.field.id == selectedSerial {
                let slot = side.slots[serial.slotIndex]
                context.saveGState()
                context.concatenate(PDFPreviewDrawing.slotTransform(slot))
                context.concatenate(PDFSerialDrawing.transform(serial))
                let box = PDFSerialDrawing.bounds(serial).insetBy(dx:-0.8,dy:-0.8)
                context.stroke(box)
                let handle = 5/pointsPerMM/scale
                for p in [CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.minX,y:box.maxY),CGPoint(x:box.maxX,y:box.maxY)] {
                    context.setFillColor(DesignSystem.paperNS.cgColor)
                    let rect = CGRect(x:p.x-handle/2,y:p.y-handle/2,width:handle,height:handle)
                    context.fill(rect); context.stroke(rect)
                }
                if let dragPosition {
                    label("X \(TRFormat.dimension(dragPosition.x)) · Y \(TRFormat.dimension(dragPosition.y)) mm",at:CGPoint(x:box.midX,y:box.maxY+8/scale),size:3,color:DesignSystem.focusNS)
                }
                context.restoreGState()
            }
        }
        context.saveGState()
        context.setAlpha(0.48)
        let guides = visibleGuideMarks.map { mark -> Mark in
            var result = mark
            if result.kind == .gripper && result.label == "Maşa 0.0 mm" { result.label = "" }
            else if let text = result.label { result.label = TRFormat.presentation(text) }
            return result
        }
        PDFPlanRenderer.drawMarks(guides,sheetSize: sheet.size,in: context,options: overlays,displayScale: scale)
        context.restoreGState()
        if overlays.generatedBleedTint == true {
            for slot in side.slots {
                let settings=slot.gangJobID.flatMap {sheet.generatedBleedByJob[$0]} ?? generatedOverlay?.settings
                guard let settings,settings.enabled,let clip=slot.artworkClip else {continue}
                context.saveGState()
                context.addRect(CGRect(x:clip.origin.x,y:clip.origin.y,width:clip.size.width,height:clip.size.height))
                context.addRect(CGRect(x:slot.x,y:slot.y,width:slot.size.width,height:slot.size.height));context.clip(using:.evenOdd)
                context.setFillColor(DesignSystem.focusNS.withAlphaComponent(0.28).cgColor)
                context.fill(CGRect(x:clip.origin.x,y:clip.origin.y,width:clip.size.width,height:clip.size.height));context.restoreGState()
            }
        }
        PDFExportMarkRenderer.draw(side:side,sheet:sheet,in:context,settings:printedMarks,info:printedInfo,kind:sideKind)
        // Screen-space emphasis is a preview overlay; PDF stroke widths stay physical.
        if printedMarks.crop || printedMarks.fullCut {
            let geometry=PDFExportMarkRenderer.geometry(side:side,sheet:sheet,settings:printedMarks)
            context.saveGState();context.setStrokeColor(NSColor.black.cgColor);context.setLineDash(phase:0,lengths:[])
            context.setLineWidth(Self.cropStrokeWidth(lineWidth:printedMarks.lineWidth,zoom:Double(scale),backing:Double(window?.backingScaleFactor ?? 1)))
            for mark in geometry.segments where mark.kind == .crop || mark.kind == .sharedCut {context.move(to:CGPoint(x:mark.start.x,y:mark.start.y));context.addLine(to:CGPoint(x:mark.end.x,y:mark.end.y));context.strokePath()}
            context.restoreGState()
        }
        if overlays.punch { PDFPlanRenderer.drawPunchMarks(side.punchMarks,in:context) }
        if let colorControls { PDFColorControlRenderer.draw(colorControls,in: context) }
        context.restoreGState()
        if let r = sheet.diagnosticBounds {
            context.saveGState(); defer { context.restoreGState() }
            context.translateBy(x: originX,y: originY); context.scaleBy(x: pointsPerMM,y: pointsPerMM)
            context.setStrokeColor(DesignSystem.errorNS.cgColor)
            context.setLineWidth(2/pointsPerMM/scale)
            context.stroke(CGRect(x: r.origin.x,y: r.origin.y,width: r.size.width,height: r.size.height))
        }
    }
    private func label(_ text: String,at point: CGPoint,size: CGFloat,color: NSColor) {
        let readableSize = max(size,11/pointsPerMM/max(0.04,enclosingScrollView?.magnification ?? 1))
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize: readableSize,weight: .semibold),
            .foregroundColor:color,.backgroundColor:DesignSystem.paperNS.withAlphaComponent(0.88)]
        let string = NSAttributedString(string: text,attributes: attributes)
        string.draw(at: CGPoint(x: point.x-string.size().width/2,y: point.y-string.size().height/2))
    }
    private func loadRaster(_ number: Int,pixels: Int) {
        guard let source, !failedRasters.contains(number), loading.insert(number).inserted else { return }
        Task { @MainActor [weak self] in
            let image = await source.image(page: number,pixels: pixels)
            guard let self, self.source === source else { return }
            self.loading.remove(number)
            if image == nil { self.failedRasters.insert(number) }
            self.needsDisplay = true
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow,from: nil)
        let point = CGPoint(x: (viewPoint.x-originX)/pointsPerMM,y: (viewPoint.y-originY)/pointsPerMM)
        if let sheet {
            for serial in sheet.serialPlacements(side: side,kind: sideKind,repetition: repetition).reversed() {
                let slot = side.slots[serial.slotIndex]
                let local = point.applying(PDFPreviewDrawing.slotTransform(slot).inverted())
                if PDFSerialDrawing.bounds(serial).insetBy(dx: -1.5,dy: -1.5)
                    .contains(local.applying(PDFSerialDrawing.transform(serial).inverted())) {
                    beginEdit?()
                    selectedSerial = serial.field.id; selectSerial?(serial.field.id)
                    serialDrag = (slot,serial.field.id,CGPoint(x: local.x-serial.position.x,y: local.y-serial.position.y),serial.position)
                    NSCursor.closedHand.push(); needsDisplay = true; return
                }
            }
        }
        if let sheet,let layout = sheet.gangLayout {
            for slot in side.slots.reversed() {
                let rect = CGRect(x:slot.x,y:slot.y,width:slot.size.width,height:slot.size.height)
                guard rect.contains(point),let id = slot.gangBlockID,let block = layout.blocks.first(where: { $0.id==id }) else { continue }
                // Map the viewed reverse / shared-plate half back to canonical front-block coordinates.
                let reflected = layout.samePlate ? ((sideKind == .back) != (slot.itemSide == .back)) : sideKind == .back
                beginEdit?()
                gangDrag = (id,block.origin,event.locationInWindow,reflected && sheet.backFlipsX,reflected && !sheet.backFlipsX)
                NSCursor.closedHand.push(); return
            }
        }
        dragPoint = event.locationInWindow; NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        if let gangDrag {
            let scale = pointsPerMM*(enclosingScrollView?.magnification ?? 1)
            let q = event.locationInWindow
            let dx = (q.x-gangDrag.start.x)/scale*(gangDrag.flipX ? -1 : 1),dy = (q.y-gangDrag.start.y)/scale*(gangDrag.flipY ? -1 : 1)
            moveGangBlock?(gangDrag.id,Point((gangDrag.origin.x+dx).rounded(),(gangDrag.origin.y+dy).rounded()))
            return
        }
        if let serialDrag {
            let p = convert(event.locationInWindow,from: nil)
            let point = CGPoint(x: (p.x-originX)/pointsPerMM,y: (p.y-originY)/pointsPerMM)
                .applying(PDFPreviewDrawing.slotTransform(serialDrag.slot).inverted())
            let position = SerialInteraction.moved(start:serialDrag.start,proposed:Point(point.x-serialDrag.offset.x,point.y-serialDrag.offset.y),modifiers:event.modifierFlags)
            dragPosition = position
            moveSerial?(serialDrag.id,position)
            needsDisplay = true
            return
        }
        guard let previous = dragPoint, let scroll = enclosingScrollView else { return }
        let now = event.locationInWindow
        var origin = scroll.contentView.bounds.origin
        origin.x -= (now.x-previous.x)/scroll.magnification
        origin.y -= (now.y-previous.y)/scroll.magnification
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(CGRect(origin: origin,size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView); dragPoint = now; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if serialDrag != nil || gangDrag != nil { endEdit?() }
        if dragPoint != nil || serialDrag != nil || gangDrag != nil { NSCursor.pop() }; dragPoint = nil; serialDrag = nil; gangDrag = nil; dragPosition = nil; needsDisplay = true
    }
    override func keyDown(with event:NSEvent) {
        guard let id = selectedSerial,let position = serialPosition?(id),let delta = SerialInteraction.nudge(event.keyCode,shift:event.modifierFlags.contains(.shift)) else { super.keyDown(with:event); return }
        beginEdit?(); moveSerial?(id,Point(position.x+delta.x,position.y+delta.y)); endEdit?(); needsDisplay = true
    }
    func connectSerialEditing(_ model:Workspace) {
        selectedSerial = model.selectedSerialID
        selectSerial = { [weak model] in model?.selectSerial($0) }
        moveSerial = { [weak model] in model?.moveSerialField($0,to:$1,snap:false) }
        serialPosition = { [weak model] id in model?.editableSerialFields.first { $0.id == id }?.position }
        beginEdit = { [weak model] in model?.beginUndoGroup() }; endEdit = { [weak model] in model?.endUndoGroup() }
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor: .openHand) }
}


extension SheetCanvasView {
    var visibleGuideMarks: [Mark] {
        side.marks.filter { mark in
            guard mark.kind == .bleed else { return true }
            guard let layout = sheet?.gangLayout else { return bleedGuideEnabled }
            let x = (mark.start.x+mark.end.x)/2, y = (mark.start.y+mark.end.y)/2
            return side.slots.contains { slot in
                guard let id = slot.gangJobID, let job = layout.jobs.first(where: { $0.job.id == id })?.job,
                      job.bleed > 0 else { return false }
                let page = slot.itemSide == .back ? job.back : job.front
                guard job.generatedBleed.enabled || (page?.availableBleed ?? 0)+0.001 >= job.bleed else { return false }
                return x >= slot.x-job.bleed-0.001 && x <= slot.x+slot.size.width+job.bleed+0.001 &&
                    y >= slot.y-job.bleed-0.001 && y <= slot.y+slot.size.height+job.bleed+0.001
            }
        }
    }
}

extension SheetCanvasView {
    static func cropStrokeWidth(lineWidth:Double,zoom:Double,backing:Double) -> Double { max(lineWidth/PDFPreviewDrawing.pointsPerMM,1.5/(PDFPreviewDrawing.pointsPerMM*max(0.001,zoom)*max(1,backing))) }
}
