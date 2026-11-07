import CoreGraphics
import CoreText
import Foundation
import ImpositionCore

/// Vector serial text shared by preview, hit testing and export, in item-local mm.
public enum PDFSerialDrawing {
    private static func line(_ placement: SerialPlacement) -> CTLine {
        let font = CTFontCreateWithName(placement.field.font as CFString,
                                       placement.field.size/PDFPreviewDrawing.pointsPerMM,nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: placement.text,attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]))
    }
    public static func transform(_ placement: SerialPlacement) -> CGAffineTransform {
        CGAffineTransform(translationX: placement.position.x,y: placement.position.y)
            .rotated(by: -placement.field.rotation * .pi/180)
    }
    public static func bounds(_ placement: SerialPlacement) -> CGRect {
        let line = line(placement)
        var ascent: CGFloat = 0,descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line,&ascent,&descent,nil)
        return CGRect(x: 0,y: -descent,width: max(width,0.5),height: ascent+descent)
    }
    public static func glyphBounds(_ placement: SerialPlacement) -> CGRect {
        CTLineGetBoundsWithOptions(line(placement),.useGlyphPathBounds)
    }
    public static func draw(_ placement: SerialPlacement,in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(transform(placement))
        let values = placement.field.color.components
        let space = values.count == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB()
        context.setFillColor(CGColor(colorSpace: space,components: (values+[1]).map { CGFloat($0) })!)
        context.textMatrix = .identity; context.textPosition = .zero
        CTLineDraw(line(placement),context)
    }
}
public struct SerialTextOverlay: PDFSlotOverlay {
    public let plan: SerialNumberPlan
    public init(plan: SerialNumberPlan) { self.plan = plan }
    public func draw(in context: CGContext,placement: PDFSlotContext) {
        // Serials are artwork, independent of proof layers and output marks.
        context.clip(to: placement.trimRect)
        for serial in plan.placements(slot: placement.slot,slotIndex: placement.reference.slot,
                                      kind: placement.reference.side,repetition: placement.repetition) {
            PDFSerialDrawing.draw(serial,in: context)
        }
    }
}
