import Foundation
import CoreGraphics
import CoreText
import ImpositionCore

public enum PDFSerialCodeDrawing {
    public struct Geometry {
        public let matrix: CodeModuleMatrix
        public let codeBounds: CGRect
        public let moduleWidth: Double
        public let moduleHeight: Double
        public let quietZone: Int
        public let rectangles: [CGRect]
    }
    public static func geometry(_ placement: SerialPlacement) throws -> Geometry {
        let field = placement.field,settings = field.codeSettings
        guard settings.isValid else { throw SerialCodeError.bitmapUnavailable }
        let matrix = try SerialCodeGenerator.shared.matrix(content: placement.content,kind: field.kind,correction: settings.correction)
        let quiet = settings.quietZone
        let module = settings.width/Double(matrix.width+2*quiet)
        let qr = field.kind == .qr
        let height = qr ? settings.width : settings.height
        let rowHeight = qr ? module : height
        let rectangles = matrix.runs.map { run in
            CGRect(x: Double(run.start+quiet)*module,
                y: qr ? height-Double(run.row+quiet+1)*module : 0,
                width: Double(run.count)*module,height: rowHeight)
        }
        return Geometry(matrix: matrix,codeBounds: CGRect(x: 0,y: 0,width: settings.width,height: height),
            moduleWidth: module,moduleHeight: rowHeight,quietZone: quiet,rectangles: rectangles)
    }
    private static func humanLine(_ placement: SerialPlacement) -> CTLine {
        let font = CTFontCreateWithName(placement.field.font as CFString,placement.field.codeSettings.humanFontSize/PDFPreviewDrawing.pointsPerMM,nil)
        let display = placement.content.replacingOccurrences(of: "\n",with: " ").replacingOccurrences(of: "\r",with: " ")
        return CTLineCreateWithAttributedString(NSAttributedString(string: display,attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true]))
    }
    private static func humanBounds(_ placement: SerialPlacement) -> (CGRect,CGPoint) {
        let line = humanLine(placement)
        var ascent: CGFloat = 0,descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line,&ascent,&descent,nil)
        let baseline = CGPoint(x: (placement.field.codeSettings.width-width)/2,y: -0.75-ascent)
        return (CGRect(x: baseline.x,y: baseline.y-descent,width: width,height: ascent+descent),baseline)
    }
    public static func bounds(_ placement: SerialPlacement) -> CGRect {
        let settings = placement.field.codeSettings
        let code = CGRect(x: 0,y: 0,width: settings.width,height: placement.field.kind == .qr ? settings.width : settings.height)
        return settings.humanReadable ? code.union(humanBounds(placement).0) : code
    }
    /// Context is already transformed into the field's local mm. Only filled
    /// paths and optional CoreText glyphs enter the PDF; no CGImage is drawn here.
    public static func drawLocal(_ placement: SerialPlacement,in context: CGContext) {
        guard let geometry = try? geometry(placement) else { return }
        let space = CGColorSpaceCreateDeviceCMYK()
        context.setFillColor(CGColor(colorSpace: space,components: [0,0,0,0,1])!)
        context.fill(bounds(placement)) // knockout background protects the quiet zone
        let channels = placement.field.color.components.count == 4 ? placement.field.color.components : [0,0,0,1]
        context.setFillColor(CGColor(colorSpace: space,components: (channels+[1]).map { CGFloat($0) })!)
        for rectangle in geometry.rectangles { context.fill(rectangle) }
        if placement.field.codeSettings.humanReadable {
            context.textMatrix = .identity; context.textPosition = humanBounds(placement).1
            CTLineDraw(humanLine(placement),context)
        }
    }
    public static func warnings(_ placement: SerialPlacement,trim: CGSize? = nil) -> [String] {
        var warnings: [String] = []
        do {
            let geometry = try geometry(placement)
            let minimum = placement.field.kind == .qr ? 0.33 : 0.25
            if geometry.moduleWidth < minimum {
                let label = placement.field.kind == .qr ? "QR modülü" : "Code 128 çubuğu"
                warnings.append(String(format: "%@ %.3f mm (< %.2f mm): kod küçük veya içerik seçilen boyuta göre çok uzun; en az %.2f mm genişlik gerekir.",
                    label,geometry.moduleWidth,minimum,Double(geometry.matrix.width+2*geometry.quietZone)*minimum))
            }
            if geometry.quietZone < (placement.field.kind == .qr ? 4 : 10) { warnings.append("Kodun sessiz alanı önerilen modül sayısından küçük; okunabilirliği kontrol edin.") }
        } catch { warnings.append(error.localizedDescription) }
        if placement.field.color.components.count != 4 { warnings.append("Kod rengi CMYK olmalıdır; K100 kullanılır.") }
        if let trim {
            let extent = bounds(placement).applying(PDFSerialDrawing.transform(placement))
            if !CGRect(origin: .zero,size: trim).contains(extent) { warnings.append("Kod / okunabilir metin kesim dışına taşıyor; kesim kutusuna kırpılır ve kod okunamayabilir.") }
        }
        return warnings
    }
}
public enum PDFSerialCodeValidation {
    /// Endpoint probes are bounded by fields/jobs, never by run quantity.
    public static func warnings(plan: ImpositionPlan) -> [String] {
        var output: [String] = []
        for (job,sheet) in plan.sheets.enumerated() {
            let recipes = (sheet.serialPlan.map { [($0,Optional<UUID>.none)] } ?? [])+(sheet.gangLayout?.jobs.map { ($0.serialPlan,Optional($0.job.id)) } ?? [])
            for (recipe,jobID) in recipes {
            for field in recipe.fields where field.kind != .text && !(recipe.frontOnly && field.sides == .back) {
                let indices = field.usesSerialNumber ? Set([0,max(0,recipe.quantity-1)]) : Set([0])
                for index in indices.sorted() {
                    let placement = SerialPlacement(field: field,slotIndex: 0,index: index,text: field.text(at: index) ?? "")
                    let relevant = [(SideKind.front,sheet.front),(.back,sheet.back)].compactMap { kind,side in
                        side.slots.first { slot in
                            if let jobID,slot.gangJobID != jobID { return false }
                            let front = (slot.itemSide ?? kind) == .front
                            return field.sides == .both || (field.sides == .front ? front : !front)
                        }
                    }.first
                    let trim = relevant.map { PDFPreviewDrawing.localTrim($0).size }
                    for warning in PDFSerialCodeDrawing.warnings(placement,trim: trim) {
                        let title = jobID.flatMap { id in sheet.gangLayout?.jobs.first { $0.job.id==id }?.job.name } ?? "İş \(sheet.repeatLayout.map { $0.jobIndex+1 } ?? job+1)"
                        let message = title+" · \(field.kind == .qr ? "QR kod" : "Barkod"): \(warning)"
                        if !output.contains(message) { output.append(message) }
                    }
                }
            }
        }
        }
        return output
    }
}
