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
    let generatedBleed: GeneratedBleedSettings
    let highlighted: Set<Int>
    let zoomAction: Int
    let zoomFactor: CGFloat
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
        scroll.contentView = CenteredClipView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.allowsMagnification = true
        scroll.minMagnification = 0.04; scroll.maxMagnification = 12
        scroll.backgroundColor = .underPageBackgroundColor
        let canvas = SheetCanvasView()
        scroll.documentView = canvas
        update(canvas)
        scroll.requestFit()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView,context: Context) {
        guard let canvas = scroll.documentView as? SheetCanvasView else { return }
        let sizeChanged = canvas.sheet?.size != sheet.size || canvas.sheet?.diagnosticBounds != sheet.diagnosticBounds
        update(canvas)
        if canvas.zoomAction != zoomAction {
            canvas.zoomAction = zoomAction
            if zoomFactor == 0 { canvas.fit() }
            else { scroll.setMagnification(min(12,max(0.04,scroll.magnification*zoomFactor)),centeredAt: scroll.documentVisibleRect.center) }
        } else if sizeChanged { (scroll as? PreviewScrollView)?.requestFit() }
    }
    private func update(_ canvas: SheetCanvasView) {
        canvas.repetition = repetition; canvas.selectedSerial = selectedSerial
        canvas.selectSerial = selectSerial; canvas.moveSerial = moveSerial; canvas.moveGangBlock = moveGangBlock; canvas.beginEdit = beginEdit; canvas.endEdit = endEdit
        canvas.configure(sheet: sheet,side: side,source: source,overlays: overlays,highlighted: highlighted,sheetIndex: sheetIndex,kind: sideKind,generatedBleed: generatedBleed,controlMarks: controlMarks)
    }
}

final class PreviewScrollView: NSScrollView {
    private var fitRequested = true
    func requestFit() { fitRequested = true; needsLayout = true }
    override func layout() {
        super.layout()
        if fitRequested, contentSize.width > 100, contentSize.height > 100,
           let canvas = documentView as? SheetCanvasView {
            fitRequested = false
            canvas.fit()
        }
    }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        documentView?.needsDisplay = true
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
    var sheet: Sheet?
    var side = Side()
    var source: PDFSource?
    var overlays = PreviewOverlays()
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
    private var serialDrag: (slot: Slot,id: UUID,offset: CGPoint)?
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
    func configure(sheet: Sheet,side: Side,source: PDFSource?,overlays: PreviewOverlays,highlighted: Set<Int>,sheetIndex: Int = 0,kind: SideKind = .front,generatedBleed: GeneratedBleedSettings = GeneratedBleedSettings(),controlMarks: ExportMarks = .none) {
        if self.source !== source {
            self.source = source; loading = []; failedRasters = []
            vectorDocument = source.flatMap { CGPDFDocument($0.url as CFURL) }
        }
        generatedOverlay = (generatedBleed.enabled || sheet.generatedBleedByJob.values.contains { $0.enabled }) ? source.map { GeneratedBleedOverlay(settings: generatedBleed,cache: $0.edgeSamples,jobSettings: sheet.generatedBleedByJob) } : nil
        var previewMarks = controlMarks
        previewMarks.colorBar = overlays.colorBar; previewMarks.registrationTargets = overlays.registrationTargets
        colorControls = overlays.colorBar || overlays.registrationTargets ? PDFColorControlRenderer.geometry(sheet: sheet,settings: previewMarks,kind: kind) : nil
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
        guard let scroll = enclosingScrollView else { return }
        let available = scroll.contentSize
        guard available.width > 100, available.height > 100 else { return }
        let factor = min(available.width/frame.width,available.height/frame.height)*0.96
        scroll.setMagnification(min(12,max(0.04,factor)),centeredAt: bounds.center)
        needsDisplay = true
    }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); needsDisplay = true }
    override func magnify(with event: NSEvent) { super.magnify(with: event); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        guard let sheet, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: originX,y: originY); context.scaleBy(x: pointsPerMM,y: pointsPerMM)
        let paper = CGRect(x: 0,y: 0,width: sheet.size.width,height: sheet.size.height)
        context.setFillColor(NSColor.white.cgColor); context.fill(paper)
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
            context.setFillColor(NSColor.white.cgColor); context.fill(rect)
            if let number = slot.sourcePageNumber {
                let page = vectorDocument?.page(at: number)
                let raster = scale < 0.85 ? source?.cachedRaster(page: number,pixels: rasterPixels) : nil
                if scale < 0.85 && raster == nil && !failedRasters.contains(number) { loadRaster(number,pixels: rasterPixels) }
                // A vector fallback avoids flashing empty trim rectangles while the bleed raster loads.
                try? PDFPlanRenderer.drawSlot(slot,page: page,in: context,
                    reference: SlotReference(sheet: sheetIndex,side: sideKind,slot: index),repetition: repetition,raster: raster,overlays: extensions)
            } else {
                context.setFillColor((slot.bookRegion == nil ? NSColor(white:0.93,alpha:1) : NSColor.white).cgColor); context.fill(rect)
                if slot.bookRegion == nil {
                    context.setStrokeColor(NSColor.lightGray.cgColor); context.setLineWidth(0.35)
                    context.move(to: rect.origin); context.addLine(to: CGPoint(x: rect.maxX,y: rect.maxY))
                    context.move(to: CGPoint(x: rect.minX,y: rect.maxY)); context.addLine(to: CGPoint(x: rect.maxX,y: rect.minY)); context.strokePath()
                }
                try? PDFPlanRenderer.drawSlot(slot,page: nil,in: context,
                    reference: SlotReference(sheet: sheetIndex,side: sideKind,slot: index),repetition: repetition,overlays: extensions)
            }
            context.restoreGState()
            if let id = slot.gangJobID,let job = sheet.gangLayout?.jobs.first(where: { $0.job.id==id })?.job {
                context.setFillColor(NSColor(calibratedHue:job.tint,saturation:0.7,brightness:0.85,alpha:0.13).cgColor); context.fill(rect)
                label(job.name,at:CGPoint(x:rect.midX,y:rect.maxY-3),size:2.5,color:NSColor(calibratedHue:job.tint,saturation:0.8,brightness:0.55,alpha:1))
            }
            context.setStrokeColor((highlighted.contains(index) ? NSColor.systemRed : NSColor.gray).cgColor)
            context.setLineWidth((highlighted.contains(index) ? 2.5 : 0.5)/pointsPerMM/scale)
            context.stroke(rect)
            if slot.rotation != 0 || slot.mirrored || slot.sourcePageNumber == nil {
                let text = slot.bookRegion ?? (slot.sourcePageNumber == nil ? "BOŞ" : [slot.rotation != 0 ? "↻ \(slot.rotation)°" : nil,slot.mirrored ? "AYNALI" : nil].compactMap{$0}.joined(separator: " · "))
                label(text,at: CGPoint(x: rect.midX,y: rect.minY+min(5,rect.height/5)),size: 3,color: .systemPurple)
            }
        }
        if let selectedSerial {
            context.setStrokeColor(NSColor.systemCyan.cgColor); context.setLineWidth(1/pointsPerMM/scale)
            for serial in sheet.serialPlacements(side: side,kind: sideKind,repetition: repetition) where serial.field.id == selectedSerial {
                let slot = side.slots[serial.slotIndex]
                context.saveGState()
                context.clip(to: CGRect(x: slot.x,y: slot.y,width: slot.size.width,height: slot.size.height))
                context.concatenate(PDFPreviewDrawing.slotTransform(slot))
                context.concatenate(PDFSerialDrawing.transform(serial))
                context.stroke(PDFSerialDrawing.bounds(serial).insetBy(dx: -0.8,dy: -0.8))
                context.restoreGState()
            }
        }
        PDFPlanRenderer.drawMarks(side.marks,sheetSize: sheet.size,in: context,options: overlays,displayScale: scale)
        if overlays.punch { PDFPlanRenderer.drawPunchMarks(side.punchMarks,in:context) }
        if let colorControls { PDFColorControlRenderer.draw(colorControls,in: context) }
        context.restoreGState()
        if let r = sheet.diagnosticBounds {
            context.saveGState(); defer { context.restoreGState() }
            context.translateBy(x: originX,y: originY); context.scaleBy(x: pointsPerMM,y: pointsPerMM)
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(2/pointsPerMM/scale)
            context.stroke(CGRect(x: r.origin.x,y: r.origin.y,width: r.size.width,height: r.size.height))
        }
    }
    private func label(_ text: String,at point: CGPoint,size: CGFloat,color: NSColor) {
        let readableSize = max(size,11/pointsPerMM/max(0.04,enclosingScrollView?.magnification ?? 1))
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize: readableSize,weight: .semibold),
            .foregroundColor:color,.backgroundColor:NSColor.white.withAlphaComponent(0.88)]
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
                guard PDFPreviewDrawing.localTrim(slot).contains(local) else { continue }
                if PDFSerialDrawing.bounds(serial).insetBy(dx: -1.5,dy: -1.5)
                    .contains(local.applying(PDFSerialDrawing.transform(serial).inverted())) {
                    beginEdit?()
                    selectedSerial = serial.field.id; selectSerial?(serial.field.id)
                    serialDrag = (slot,serial.field.id,CGPoint(x: local.x-serial.position.x,y: local.y-serial.position.y))
                    NSCursor.crosshair.push(); needsDisplay = true; return
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
            let trim = PDFPreviewDrawing.localTrim(serialDrag.slot)
            let snapped = Point(max(0,min((trim.width-1).rounded(.down),(point.x-serialDrag.offset.x).rounded())),
                                max(0,min((trim.height-1).rounded(.down),(point.y-serialDrag.offset.y).rounded())))
            moveSerial?(serialDrag.id,snapped)
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
        if dragPoint != nil || serialDrag != nil || gangDrag != nil { NSCursor.pop() }; dragPoint = nil; serialDrag = nil; gangDrag = nil
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor: .openHand) }
}
