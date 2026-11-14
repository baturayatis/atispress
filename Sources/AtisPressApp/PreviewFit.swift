import AppKit
import ImpositionCore
import PDFEngine

/// Screen geometry only. No production or export dimensions are changed.
enum PreviewFit {
    enum Mode { case width, whole }
    static let inset:CGFloat = 16
    static func scale(document:CGSize,paper:Size,viewport:CGSize,mode:Mode) -> CGFloat {
        guard document.width>0,document.height>0,viewport.width>2*inset,viewport.height>2*inset else { return 1 }
        let width = (viewport.width-2*inset)/document.width
        let available = mode == .width ? width : min(width,(viewport.height-2*inset)/document.height)
        // Below A4 area, keep at most actual size. A4 and larger may grow to 300%.
        let cap:CGFloat = paper.width*paper.height < 210*297-0.01 ? 1 : 3
        return max(0.001,min(cap,available))
    }
}

/// Shared automatic/manual zoom lifecycle for both preview presentations.
class AutoFitScrollView:NSScrollView {
    weak var zoomModel:Workspace?
    var autoFitEnabled = true
    var fitRequested = true
    var zoomAction = -1
    private var fitting = false
    private var lastViewport = CGSize.zero
    private var lastDocument = CGSize.zero
    private var lastPaper = Size(0,0)
    var fitMode:PreviewFit.Mode { .whole }
    var fitDocumentSize:CGSize { documentView?.frame.size ?? .zero }
    var fitPaperSize:Size { (documentView as? SheetCanvasView)?.sheet?.size ?? Size(0,0) }
    func preserveFitPosition() -> (() -> Void) { {} }
    func requestFit() { fitRequested = true; needsLayout = true }
    func synchronizeZoom(_ model:Workspace) {
        zoomModel = model
        let initial = zoomAction < 0
        let changed = zoomAction != model.zoomAction
        zoomAction = model.zoomAction
        autoFitEnabled = model.zoomAutomatic
        hasHorizontalScroller = !autoFitEnabled
        if autoFitEnabled {
            if changed || initial { requestFit() }
        } else if initial {
            setMagnification(min(maxMagnification,max(minMagnification,model.zoomScale)),centeredAt:documentVisibleRect.origin)
        } else if changed {
            manualZoom(by:model.zoomFactor)
        }
    }
    func manualZoom(by factor:CGFloat) {
        autoFitEnabled = false; fitRequested = false; hasHorizontalScroller = true
        // Native gestures arrive outside SwiftUI updates; pause before a resize can refit.
        if zoomModel?.zoomAutomatic == true { zoomModel?.zoomAutomatic = false }
        setMagnification(min(maxMagnification,max(minMagnification,magnification*factor)),centeredAt:documentVisibleRect.origin)
        reportZoom(manual:true)
    }
    private func reportZoom(manual:Bool) {
        guard let model = zoomModel else { return }
        let scale = magnification, action = model.zoomAction
        DispatchQueue.main.async { [weak model] in
            guard let model,model.zoomAction == action else { return }
            if manual { model.zoomAutomatic = false }
            if abs(model.zoomScale-scale)>0.00001 { model.zoomScale = scale }
        }
    }
    override func layout() {
        super.layout()
        guard !fitting else { return }
        let viewport = contentSize, document = fitDocumentSize, paper = fitPaperSize
        guard autoFitEnabled,viewport.width>32,viewport.height>32,document.width>0,document.height>0,
              fitRequested || viewport != lastViewport || document != lastDocument || paper != lastPaper else { return }
        fitting = true; defer { fitting = false }
        fitRequested = false
        hasHorizontalScroller = false
        let restore = preserveFitPosition()
        let factor = PreviewFit.scale(document:document,paper:paper,viewport:contentSize,mode:fitMode)
        setMagnification(factor,centeredAt:documentVisibleRect.origin)
        restore()
        lastViewport = contentSize; lastDocument = fitDocumentSize; lastPaper = fitPaperSize
        documentView?.needsDisplay = true
        reportZoom(manual:false)
    }
    override func magnify(with event:NSEvent) {
        autoFitEnabled = false; fitRequested = false; hasHorizontalScroller = true
        if zoomModel?.zoomAutomatic == true { zoomModel?.zoomAutomatic = false }
        super.magnify(with:event)
        reportZoom(manual:true); documentView?.needsDisplay = true
    }
    override func scrollWheel(with event:NSEvent) {
        if event.modifierFlags.contains(.command) { manualZoom(by:exp(-event.scrollingDeltaY*0.01)) }
        else { super.scrollWheel(with:event) }
    }
}

/// Keep small, actual-size sheets centered without changing the vertical reading flow.
final class PreviewWidthClipView:NSClipView {
    override func constrainBoundsRect(_ proposedBounds:NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView,document.frame.width < rect.width {
            rect.origin.x = (document.frame.width-rect.width)/2
        }
        return rect
    }
}
