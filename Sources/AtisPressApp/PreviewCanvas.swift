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
        let sizeChanged = canvas.sheet?.size != sheet.size
        update(canvas)
        if canvas.zoomAction != zoomAction {
            canvas.zoomAction = zoomAction
            if zoomFactor == 0 { canvas.fit() }
            else { scroll.setMagnification(min(12,max(0.04,scroll.magnification*zoomFactor)),centeredAt: scroll.documentVisibleRect.center) }
        } else if sizeChanged { (scroll as? PreviewScrollView)?.requestFit() }
    }
    private func update(_ canvas: SheetCanvasView) {
        canvas.configure(sheet: sheet,side: side,source: source,overlays: overlays,highlighted: highlighted,sheetIndex: sheetIndex,kind: sideKind,generatedBleed: generatedBleed)
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
    func configure(sheet: Sheet,side: Side,source: PDFSource?,overlays: PreviewOverlays,highlighted: Set<Int>,sheetIndex: Int = 0,kind: SideKind = .front,generatedBleed: GeneratedBleedSettings = GeneratedBleedSettings()) {
        if self.source !== source {
            self.source = source; loading = []; failedRasters = []
            vectorDocument = source.flatMap { CGPDFDocument($0.url as CFURL) }
        }
        generatedOverlay = generatedBleed.enabled ? source.map { GeneratedBleedOverlay(settings: generatedBleed,cache: $0.edgeSamples) } : nil
        self.sheetIndex = sheetIndex; self.sideKind = kind
        self.sheet = sheet; self.side = side; self.overlays = overlays; self.highlighted = highlighted
        let newSize = NSSize(width: sheet.size.width*pointsPerMM+2*padding,height: sheet.size.height*pointsPerMM+2*padding)
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
        context.translateBy(x: padding,y: padding); context.scaleBy(x: pointsPerMM,y: pointsPerMM)
        let paper = CGRect(x: 0,y: 0,width: sheet.size.width,height: sheet.size.height)
        context.setFillColor(NSColor.white.cgColor); context.fill(paper)
        context.clip(to: paper)
        let scale = max(0.01,enclosingScrollView?.magnification ?? 1)
        let visible = visibleRect.insetBy(dx: -40,dy: -40)
        let extensions: [any PDFSlotOverlay] = (generatedOverlay.map { [$0 as any PDFSlotOverlay] } ?? [])+slotOverlays
        for (index,slot) in side.slots.enumerated() {
            let rect = CGRect(x: slot.x,y: slot.y,width: slot.size.width,height: slot.size.height)
            let extent = slot.artworkClip.map { CGRect(x: $0.origin.x,y: $0.origin.y,width: $0.size.width,height: $0.size.height) } ?? rect
            let viewRect = CGRect(x: extent.minX*pointsPerMM+padding,y: extent.minY*pointsPerMM+padding,
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
                    reference: SlotReference(sheet: sheetIndex,side: sideKind,slot: index),raster: raster,overlays: extensions)
            } else {
                context.setFillColor(NSColor(white: 0.93,alpha: 1).cgColor); context.fill(rect)
                context.setStrokeColor(NSColor.lightGray.cgColor); context.setLineWidth(0.35)
                context.move(to: rect.origin); context.addLine(to: CGPoint(x: rect.maxX,y: rect.maxY))
                context.move(to: CGPoint(x: rect.minX,y: rect.maxY)); context.addLine(to: CGPoint(x: rect.maxX,y: rect.minY)); context.strokePath()
                try? PDFPlanRenderer.drawSlot(slot,page: nil,in: context,
                    reference: SlotReference(sheet: sheetIndex,side: sideKind,slot: index),overlays: extensions)
            }
            context.restoreGState()
            context.setStrokeColor((highlighted.contains(index) ? NSColor.systemRed : NSColor.gray).cgColor)
            context.setLineWidth((highlighted.contains(index) ? 2.5 : 0.5)/pointsPerMM/scale)
            context.stroke(rect)
            if slot.rotation != 0 || slot.mirrored || slot.sourcePageNumber == nil {
                let text = slot.sourcePageNumber == nil ? "BOŞ" : [slot.rotation != 0 ? "↻ \(slot.rotation)°" : nil,slot.mirrored ? "AYNALI" : nil].compactMap{$0}.joined(separator: " · ")
                label(text,at: CGPoint(x: rect.midX,y: rect.minY+min(5,rect.height/5)),size: 3,color: .systemPurple)
            }
        }
        PDFPlanRenderer.drawMarks(side.marks,sheetSize: sheet.size,in: context,options: overlays,displayScale: scale)
        context.restoreGState()
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
        window?.makeFirstResponder(self); dragPoint = event.locationInWindow; NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint, let scroll = enclosingScrollView else { return }
        let now = event.locationInWindow
        var origin = scroll.contentView.bounds.origin
        origin.x -= (now.x-previous.x)/scroll.magnification
        origin.y -= (now.y-previous.y)/scroll.magnification
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(CGRect(origin: origin,size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView); dragPoint = now; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if dragPoint != nil { NSCursor.pop() }; dragPoint = nil
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor: .openHand) }
}
