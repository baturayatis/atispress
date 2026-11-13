import CoreGraphics
import CoreText
import Foundation
import ImpositionCore

public struct PDFRenderOptions: Equatable, Sendable, Codable {
    public var punchVisible: Bool? = nil
    public var punch: Bool { get { punchVisible ?? true } set { punchVisible = newValue } }
    public var crop: Bool
    public var fold: Bool
    public var bleed: Bool
    public var safeArea: Bool
    public var pageNumbers: Bool
    public var sheetBoundary: Bool
    public var pressGuides: Bool
    // Optional storage keeps version 1–6 preview settings readable.
    public var colorBarVisible: Bool? = nil
    public var targetsVisible: Bool? = nil
    public var manualColorBar: Bool? = nil
    public var manualTargets: Bool? = nil
    public var colorBar: Bool {
        get { colorBarVisible ?? false }
        set { colorBarVisible = newValue }
    }
    public var registrationTargets: Bool {
        get { targetsVisible ?? false }
        set { targetsVisible = newValue }
    }
    public init(crop: Bool = true,fold: Bool = true,bleed: Bool = true,safeArea: Bool = false,
                pageNumbers: Bool = true,sheetBoundary: Bool = true,pressGuides: Bool = true,punch: Bool = true) {
        self.crop = crop; self.fold = fold; self.bleed = bleed; self.safeArea = safeArea
        self.punchVisible = punch
        self.pageNumbers = pageNumbers; self.sheetBoundary = sheetBoundary; self.pressGuides = pressGuides
    }
    public static let artworkOnly = PDFRenderOptions(crop: false,fold: false,bleed: false,safeArea: false,
                                                     pageNumbers: false,sheetBoundary: false,pressGuides: false,punch: false)
    public func shows(_ kind: MarkKind) -> Bool {
        switch kind {
        case .crop,.sharedCut: return crop
        case .fold: return fold
        case .bleed: return bleed
        case .safeArea: return safeArea
        case .pageLabel: return pageNumbers
        case .margin,.gripper: return pressGuides
        }
    }
}

public enum PDFOverlayPhase: Sendable { case underArtwork, overArtwork }
public struct PDFSlotContext {
    public let slot: Slot
    public let reference: SlotReference
    /// Zero-based physical repetition of this plan sheet.
    public let repetition: Int
    public let trimRect: CGRect
    public let artworkRect: CGRect
    public let sourcePage: CGPDFPage?
}
/// Drawing is in slot-local trim millimetres, before its rotation/reflection.
/// The graphics state and the plan's shared-cut/bleed clip are isolated for every hook.
/// Implement vector drawing here for serials, variable text or generated bleed later.
public protocol PDFSlotOverlay: Sendable {
    var phase: PDFOverlayPhase { get }
    func draw(in context: CGContext,placement: PDFSlotContext) throws
}
public extension PDFSlotOverlay { var phase: PDFOverlayPhase { .overArtwork } }

public enum PDFPlanRenderer {
    public static func drawSlot(_ slot: Slot,page: CGPDFPage?,in context: CGContext,
                                reference: SlotReference,repetition: Int = 0,raster: PDFPageRaster? = nil,
                                overlays: [any PDFSlotOverlay] = []) throws {
        context.saveGState()
        defer { context.restoreGState() }
        let placementTransform = PDFPreviewDrawing.bindingTransform(slot)
        let transform = PDFPreviewDrawing.slotTransform(slot).concatenating(placementTransform)
        let trim = PDFPreviewDrawing.localTrim(slot)
        var localClip = trim
        if let clip = slot.artworkClip {
            let bounds = CGRect(x: clip.origin.x,y: clip.origin.y,width: clip.size.width,height: clip.size.height)
            context.clip(to: bounds)
            localClip = bounds.applying(transform.inverted())
        }
        func extensionsFor(_ phase: PDFOverlayPhase) throws {
            let art = phase == .underArtwork ? localClip.offsetBy(dx:-slot.artworkOffset.x,dy:-slot.artworkOffset.y) : localClip
            let placement = PDFSlotContext(slot:slot,reference:reference,repetition:repetition,trimRect:trim,artworkRect:art,sourcePage:page)
            for overlay in overlays where overlay.phase == phase {
                context.saveGState(); defer { context.restoreGState() }
                try overlay.draw(in:context,placement:placement)
            }
        }
        func artwork() throws {
            context.saveGState(); defer { context.restoreGState() }
            context.concatenate(placementTransform)
            context.concatenate(PDFPreviewDrawing.slotTransform(slot))
            context.translateBy(x:slot.artworkOffset.x,y:slot.artworkOffset.y)
            try extensionsFor(.underArtwork)
            if slot.sourcePageNumber != nil {
                if let page,let scale = slot.rescale {
                    PDFRescaleDrawing.draw(page,scale:scale,in:context)
                } else if let raster {
                    let r = raster.normalizedArtworkBounds
                    context.draw(raster.cgImage,in:CGRect(x:r.minX*trim.width,y:r.minY*trim.height,width:r.width*trim.width,height:r.height*trim.height))
                } else if let page { PDFPreviewDrawing.draw(page,in:context,rect:trim) }
            }
        }
        try artwork()
        context.concatenate(PDFPreviewDrawing.slotTransform(slot))
        try extensionsFor(.overArtwork)
    }
    /// Context units are sheet millimetres. Only document content and selected plan marks are drawn.
    public static func drawSide(_ side: Side,sheet: Sheet,document: CGPDFDocument,in context: CGContext,
                                sheetIndex: Int,kind: SideKind,repetition: Int,options: PDFRenderOptions,
                                overlays: [any PDFSlotOverlay] = [],controlMarks: ExportMarks = .none) throws {
        let serials: [any PDFSlotOverlay] = [GangSerialOverlay(sheet: sheet)]
        for (index,slot) in side.slots.enumerated() {
            try Task.checkCancellation()
            let page = slot.sourcePageNumber.flatMap { document.page(at: $0) }
            if slot.sourcePageNumber != nil && page == nil { throw PDFExportError.missingPage(slot.sourcePageNumber!) }
            try drawSlot(slot,page: page,in: context,reference: SlotReference(sheet: sheetIndex,side: kind,slot: index),
                         repetition: repetition,overlays: overlays+serials)
        }
        drawMarks(side.marks,sheetSize: sheet.size,in: context,options: options)
        if options.punch { drawPunchMarks(side.punchMarks,in:context) }
        if options.colorBar || options.registrationTargets {
            var marks = controlMarks
            marks.colorBar = options.colorBar; marks.registrationTargets = options.registrationTargets
            PDFColorControlRenderer.draw(PDFColorControlRenderer.geometry(sheet: sheet,settings: marks,kind: kind),in: context)
        }
    }
    public static func drawPunchMarks(_ marks: [PunchMark],in context: CGContext,color: CGColor? = nil) {
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(color ?? CGColor(colorSpace:CGColorSpaceCreateDeviceCMYK(),components:[0,0,0,1,1])!)
        context.setLineDash(phase:0,lengths:[]); context.setLineWidth(0.25/PDFPreviewDrawing.pointsPerMM)
        for mark in marks {
            let b = mark.bounds
            context.strokeEllipse(in:CGRect(x:b.origin.x,y:b.origin.y,width:b.size.width,height:b.size.height))
        }
    }
    public static func drawMarks(_ marks: [Mark],sheetSize: Size,in context: CGContext,
                                 options: PDFRenderOptions,displayScale: Double? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        let minimumStroke = displayScale.map { 1/(PDFPreviewDrawing.pointsPerMM*max(0.04,$0)) } ?? 0
        for mark in marks where options.shows(mark.kind) {
            let color: CGColor
            switch mark.kind {
            case .crop,.sharedCut: color = CGColor(gray: 0,alpha: 1)
            case .fold,.pageLabel: color = CGColor(red: 0,green: 0.35,blue: 0.85,alpha: 1)
            case .bleed: color = CGColor(red: 0.9,green: 0.08,blue: 0.1,alpha: 1)
            case .safeArea: color = CGColor(red: 0,green: 0.55,blue: 0.2,alpha: 1)
            case .margin,.gripper: color = CGColor(red: 0.85,green: 0.4,blue: 0,alpha: 1)
            }
            if mark.kind == .pageLabel {
                drawLabel(mark.label ?? "",at: CGPoint(x: mark.start.x,y: mark.start.y),size: 4,
                          color: color,in: context,displayScale: displayScale)
                continue
            }
            context.setLineWidth(max(mark.kind == .gripper ? 0.4 : 0.25,minimumStroke))
            context.setStrokeColor(color)
            context.setLineDash(phase: 0,lengths: mark.kind == .crop || mark.kind == .sharedCut || mark.kind == .gripper ? [] : [2,1])
            context.move(to: CGPoint(x: mark.start.x,y: mark.start.y))
            context.addLine(to: CGPoint(x: mark.end.x,y: mark.end.y)); context.strokePath()
            if mark.kind == .gripper {
                drawLabel(mark.label ?? "Maşa",at: CGPoint(x: (mark.start.x+mark.end.x)/2,y: (mark.start.y+mark.end.y)/2),
                          size: 3,color: color,in: context,displayScale: displayScale)
            }
        }
        if options.sheetBoundary {
            context.setLineDash(phase: 0,lengths: [])
            context.setStrokeColor(CGColor(gray: 0,alpha: 1)); context.setLineWidth(max(0.35,minimumStroke))
            context.stroke(CGRect(x: 0,y: 0,width: sheetSize.width,height: sheetSize.height))
        }
    }
    public static func drawLabel(_ text: String,at point: CGPoint,size: Double,color: CGColor,
                                 in context: CGContext,displayScale: Double? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        let readable = displayScale.map { max(size,11/PDFPreviewDrawing.pointsPerMM/max(0.04,$0)) } ?? size
        let font = CTFontCreateWithName("Menlo-Bold" as CFString,readable,nil)
        let string = NSAttributedString(string: text,attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):color
        ])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line,&ascent,&descent,nil)
        let origin = CGPoint(x: point.x-width/2,y: point.y-(ascent-descent)/2)
        context.setFillColor(CGColor(gray: 1,alpha: 0.88))
        context.fill(CGRect(x: origin.x,y: origin.y-descent,width: width,height: ascent+descent))
        context.textMatrix = .identity; context.textPosition = origin
        CTLineDraw(line,context)
    }
}
