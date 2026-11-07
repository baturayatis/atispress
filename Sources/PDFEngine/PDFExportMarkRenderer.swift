import CoreGraphics
import ImpositionCore

/// Production-only rendering. All strokes (including their width) are kept clear
/// of planned artwork/bleed. Preview colors and dash patterns never enter here.
public enum PDFExportMarkRenderer {
    public struct Geometry {
        public var segments: [Mark]
        public var warnings: [String]
    }
    public static func geometry(side: Side,sheet: Sheet,settings: ExportMarks) -> Geometry {
        let half = max(0.01,settings.lineWidth.isFinite ? settings.lineWidth : 0.25)/PDFPreviewDrawing.pointsPerMM/2
        let paper = CGRect(x: half,y: half,width: sheet.size.width-2*half,height: sheet.size.height-2*half)
        let boxes = side.slots.map { slot -> CGRect in
            let r = slot.artworkClip
            return CGRect(x: r?.origin.x ?? slot.x,y: r?.origin.y ?? slot.y,
                          width: r?.size.width ?? slot.size.width,height: r?.size.height ?? slot.size.height).insetBy(dx: -half,dy: -half)
        }
        var output: [Mark] = [], blocked = false, outside = false
        for mark in side.marks {
            let selected: Bool
            switch mark.kind {
            case .crop,.sharedCut: selected = settings.crop || settings.fullCut
            case .fold: selected = settings.fold
            case .bleed: selected = settings.bleed
            case .safeArea: selected = settings.safeArea
            default: selected = false
            }
            guard selected else { continue }
            let horizontal = abs(mark.start.y-mark.end.y) < 0.000001
            let vertical = abs(mark.start.x-mark.end.x) < 0.000001
            guard horizontal || vertical else { continue }
            let fixed = horizontal ? mark.start.y : mark.start.x
            var lo = horizontal ? min(mark.start.x,mark.end.x) : min(mark.start.y,mark.end.y)
            var hi = horizontal ? max(mark.start.x,mark.end.x) : max(mark.start.y,mark.end.y)
            if settings.fullCut && (mark.kind == .crop || mark.kind == .sharedCut) {
                lo = 0; hi = horizontal ? sheet.size.width : sheet.size.height
            }
            let paperLo = horizontal ? paper.minX : paper.minY, paperHi = horizontal ? paper.maxX : paper.maxY
            if fixed < (horizontal ? paper.minY : paper.minX) || fixed > (horizontal ? paper.maxY : paper.maxX) {
                outside = true; continue
            }
            if lo < paperLo || hi > paperHi { outside = true }
            var intervals = [(max(lo,paperLo),min(hi,paperHi))].filter { $0.1 > $0.0 }
            for box in boxes where fixed >= (horizontal ? box.minY : box.minX) && fixed <= (horizontal ? box.maxY : box.maxX) {
                let a = horizontal ? box.minX : box.minY, b = horizontal ? box.maxX : box.maxY
                intervals = intervals.flatMap { l,h -> [(Double,Double)] in
                    guard b > l && a < h else { return [(l,h)] }
                    blocked = true
                    return [(l,min(h,a)),(max(l,b),h)].filter { $0.1-$0.0 > 0.001 }
                }
            }
            for (l,h) in intervals {
                output.append(Mark(kind: mark.kind,start: horizontal ? Point(l,fixed) : Point(fixed,l),
                                   end: horizontal ? Point(h,fixed) : Point(fixed,h)))
            }
        }
        var warnings: [String] = []
        if blocked { warnings.append("İşaretler için ara boşluk yetersiz: taşma/artwork ile çakışan bölümler çıkarıldı.") }
        if outside { warnings.append("İşaretler tabaka sınırını aşıyor: tabaka dışındaki bölümler çıkarıldı.") }
        if settings.safeArea || settings.bleed || settings.fullCut {
            warnings.append("Artwork ve taşma korunur; iç kılavuzlar ve tam kesim çizgilerinin artwork üzerindeki bölümleri basılmaz.")
        }
        return Geometry(segments: output,warnings: warnings)
    }
    public static func draw(side: Side,sheet: Sheet,in context: CGContext,settings: ExportMarks,info: String) {
        guard settings.crop || settings.fold || settings.bleed || settings.safeArea || settings.pageNumbers || settings.sheetInfo || settings.fullCut else { return }
        context.saveGState(); defer { context.restoreGState() }
        let width = max(0.01,settings.lineWidth.isFinite ? settings.lineWidth : 0.25)/PDFPreviewDrawing.pointsPerMM
        let color = CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(),components:
            settings.color == .black ? [0,0,0,1,1] : [1,1,1,1,1])!
        context.setStrokeColor(color); context.setFillColor(color)
        context.setLineWidth(width); context.setLineCap(.butt); context.setLineDash(phase: 0,lengths: [])
        for mark in geometry(side: side,sheet: sheet,settings: settings).segments {
            context.move(to: CGPoint(x: mark.start.x,y: mark.start.y))
            context.addLine(to: CGPoint(x: mark.end.x,y: mark.end.y)); context.strokePath()
        }
        guard settings.pageNumbers || settings.sheetInfo else { return }
        // Clip text against every artwork box, including the text's white backing.
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0,y: 0,width: sheet.size.width,height: sheet.size.height))
        // Sequential difference clips avoid even-odd overlap reopening protected areas.
        for slot in side.slots {
            let r = slot.artworkClip
            let box = CGRect(x: r?.origin.x ?? slot.x,y: r?.origin.y ?? slot.y,
                             width: r?.size.width ?? slot.size.width,height: r?.size.height ?? slot.size.height)
            let exclusion = CGMutablePath(); exclusion.addPath(path); exclusion.addRect(box.insetBy(dx: -width,dy: -width))
            context.addPath(exclusion); context.clip(using: .evenOdd)
        }
        if settings.pageNumbers {
            for (index,slot) in side.slots.enumerated() {
                let r = slot.artworkClip
                PDFPlanRenderer.drawLabel("\(slot.sourcePageNumber.map(String.init) ?? "Boş") / \(index+1)",
                    at: CGPoint(x: slot.x+slot.size.width/2,y: (r?.origin.y ?? slot.y)-2),size: 2,color: color,in: context)
            }
        }
        if settings.sheetInfo {
            if let placement = PDFSheetInfo.placement(text: info,side: side,sheet: sheet,marks: settings) {
                PDFSheetInfo.draw(placement,color: color,in: context)
            }
        }
    }
}
