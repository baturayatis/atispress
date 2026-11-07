import Foundation
import CoreGraphics
import CoreText
import ImpositionCore

public struct PDFSheetInfoContext: Sendable {
    public var jobName: String
    public var date: Date
    public var sheetNumber: Int
    public var totalSheets: Int
    public var side: SideKind
    public var production: ProductionType
    public init(jobName: String,date: Date = Date(),sheetNumber: Int,totalSheets: Int,side: SideKind,production: ProductionType = .digital) {
        self.jobName = jobName; self.date = date; self.sheetNumber = sheetNumber; self.totalSheets = totalSheets
        self.side = side; self.production = production
    }
    public func text(settings: SheetInfoSettings,sheet: Sheet,dateLabel: String? = nil) -> String {
        var fields: [String] = []
        if settings.showJobName { fields.append(settings.jobName ?? jobName) }
        if settings.date { fields.append(dateLabel ?? Self.formattedDate(date)) }
        if settings.sheetNumber { fields.append("Tabaka \(sheetNumber) / \(totalSheets)") }
        if settings.side { fields.append(side == .front ? "Ön" : "Arka") }
        if settings.sheetSize { fields.append(String(format: "%.1f×%.1f mm",sheet.size.width,sheet.size.height)) }
        if settings.production { fields.append(production == .offset ? "Ofset" : "Dijital") }
        return fields.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func formattedDate(_ date: Date) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "tr_TR"); format.dateFormat = "dd.MM.yyyy"
        return format.string(from: date)
    }
}
public enum PDFSheetInfo {
    public struct Placement {
        public var bounds: CGRect
        public var baseline: CGPoint
        public var text: String
    }
    public static let noRoomWarning = "Tabaka bilgi şeridi için boş kenar alanı yok; şerit çıktıya eklenmedi."
    private static let unit = PDFPreviewDrawing.pointsPerMM
    private static func line(_ text: String,color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,6/unit,nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):color
        ]))
    }
    public static func placement(text: String,side: Side,sheet: Sheet,marks: ExportMarks,kind: SideKind = .front) -> Placement? {
        guard !text.isEmpty else { return nil }
        let line = line(text,color: CGColor(gray: 0,alpha: 1))
        var ascent: CGFloat = 0,descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line,&ascent,&descent,nil)+0.5,height = ascent+descent+0.5
        let paper = CGRect(x: 0.5,y: 0.5,width: sheet.size.width-1,height: sheet.size.height-1)
        guard width > 0,height > 0,paper.width >= width,paper.height >= height else { return nil }
        let artwork = side.slots.map { slot -> CGRect in
            let r = slot.artworkClip
            return CGRect(x: r?.origin.x ?? slot.x,y: r?.origin.y ?? slot.y,
                width: r?.size.width ?? slot.size.width,height: r?.size.height ?? slot.size.height).insetBy(dx: -0.25,dy: -0.25)
        }
        let edge = max(0.01,marks.lineWidth.isFinite ? marks.lineWidth : 0.25)/unit/2+0.25
        var protected = artwork
        protected += PDFColorControlRenderer.geometry(sheet: sheet,settings: marks,kind: kind).bounds.map { $0.insetBy(dx: -0.25,dy: -0.25) }
        protected += PDFExportMarkRenderer.geometry(side: side,sheet: sheet,settings: marks).segments.map {
            CGRect(x: min($0.start.x,$0.end.x)-edge,y: min($0.start.y,$0.end.y)-edge,
                   width: abs($0.end.x-$0.start.x)+2*edge,height: abs($0.end.y-$0.start.y)+2*edge)
        }
        if marks.pageNumbers {
            for (index,slot) in side.slots.enumerated() {
                let text = "\(slot.sourcePageNumber.map(String.init) ?? "Boş") / \(index+1)"
                let font = CTFontCreateWithName("Menlo-Bold" as CFString,2,nil)
                let label = CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: [NSAttributedString.Key(kCTFontAttributeName as String):font]))
                var a: CGFloat = 0,d: CGFloat = 0
                let w = CTLineGetTypographicBounds(label,&a,&d,nil)
                protected.append(CGRect(x: slot.x+slot.size.width/2-w/2-0.25,
                    y: (slot.artworkClip?.origin.y ?? slot.y)-2-(a+d)/2-0.25,width: w+0.5,height: a+d+0.5))
            }
        }
        let block = artwork.reduce(CGRect.null) { $0.union($1) }
        let bands = block.isNull ? [paper] : [
            CGRect(x: paper.minX,y: paper.minY,width: paper.width,height: max(0,block.minY-paper.minY)),
            CGRect(x: paper.minX,y: block.maxY,width: paper.width,height: max(0,paper.maxY-block.maxY)),
            CGRect(x: paper.minX,y: paper.minY,width: max(0,block.minX-paper.minX),height: paper.height),
            CGRect(x: block.maxX,y: paper.minY,width: max(0,paper.maxX-block.maxX),height: paper.height)
        ]
        for band in bands where band.width >= width && band.height >= height {
            let xs = [band.midX-width/2,band.minX,band.maxX-width]
            var ys = [band.minY,band.maxY-height]
            ys += protected.flatMap { [$0.minY-height-0.01,$0.maxY+0.01] }.filter { $0 >= band.minY && $0+height <= band.maxY }
            var seenY = Set<Double>()
            for y in ys where seenY.insert(y).inserted {
                for x in xs {
                    let box = CGRect(x: x,y: y,width: width,height: height)
                    guard paper.contains(box),band.contains(box),!protected.contains(where: { $0.intersects(box) }) else { continue }
                    return Placement(bounds: box,baseline: CGPoint(x: x+0.25,y: y+0.25+descent),text: text)
                }
            }
        }
        return nil
    }
    public static func draw(_ placement: Placement,color: CGColor,in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.textMatrix = .identity; context.textPosition = placement.baseline
        CTLineDraw(line(placement.text,color: color),context)
    }
}
