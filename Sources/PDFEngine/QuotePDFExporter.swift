import Foundation
import AppKit
import CoreText
import ImpositionCore

/// A single vector text page; optional logos retain the supplied image/PDF representation.
public enum QuotePDFExporter {
    public static func export(project: Project,result: CostResult,library: PriceLibrary,to url: URL,date: Date = Date()) throws {
        let s = project.costing ?? JobCostSettings(), q = s.quote
        guard let sale = result.sale,let tax = result.tax,result.missing.isEmpty,!q.validity.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CostError.incomplete }
        let money: (Decimal?) -> String = { value in
            guard let value else { return "girilmedi" }
            let f = NumberFormatter(); f.locale = Locale(identifier:"tr_TR"); f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
            return (f.string(from:value as NSDecimalNumber) ?? "girilmedi") + " ₺"
        }
        let df = DateFormatter(); df.locale = Locale(identifier:"tr_TR"); df.dateFormat = "dd.MM.yyyy"
        let paper = s.paper?.resolved(in:library), printing = s.printing?.resolved(in:library)
        let size = project.pages.first?.trimSize
        let product = size.map { "\($0.width) × \($0.height) mm" } ?? "girilmedi"
        let binding: String
        switch project.binding {
        case .saddleStitch: binding = "Tel dikiş"
        case .perfectBound: binding = "Tutkallı cilt"
        case .sewn: binding = "Dikişli cilt"
        case .spiral: binding = "Spiral"
        case .wireO: binding = "Wire-O"
        case .stepAndRepeat, .gang: binding = "Düz iş"
        }
        var lines: [(String,String)] = [
            ("İş adı",q.jobName), ("Tarih",df.string(from:date)), ("Ürün / ebat",product),
            ("Adet",String(result.quantity)), ("Kâğıt",paper.map { "\($0.name) · \($0.grammage.map { String($0) } ?? "girilmedi") g/m²" } ?? "girilmedi"),
            ("Baskı",printing.map { $0.name + " · " + $0.kind.rawValue } ?? "girilmedi"),
            ("Cilt / işçilik",([binding] + s.finishing.compactMap { $0.resolved(in:library)?.name }).joined(separator:", ")),
            ("Adet fiyatı (KDV dahil)",money(result.perCopy)), ("KDV",money(tax)), ("Toplam (KDV dahil)",money(sale)), ("Geçerlilik",q.validity), ("Not",q.note)
        ]
        if q.showCosts {
            lines.append(("Maliyet dökümü",""))
            lines += result.lines.map { ($0.name,"\($0.quantity) × \(money($0.unitPrice)) = \(money($0.amount))") }
            lines += [("Toplam maliyet",money(result.cost)),("Kâr",money(result.profit))]
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data:data) else { throw CostError.incomplete }
        var box = CGRect(x:0,y:0,width:595.28,height:841.89)
        guard let context = CGContext(consumer:consumer,mediaBox:&box,nil) else { throw CostError.incomplete }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(box)
        var logoWidth: CGFloat = 0
        if let logo = q.logo,let image = NSImage(data:logo) {
            let ratio = min(110/max(1,image.size.width),55/max(1,image.size.height))
            let rect = CGRect(x:443,y:748,width:image.size.width*ratio,height:image.size.height*ratio)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            image.draw(in:rect); NSGraphicsContext.restoreGraphicsState(); logoWidth = 125
        }
        func text(_ value: String,rect: CGRect,font: CGFloat,bold: Bool = false) -> Bool {
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont(name:bold ? "Helvetica-Bold" : "Helvetica",size:font)!, .foregroundColor:NSColor(calibratedRed:0.12,green:0.18,blue:0.25,alpha:1)]
            let string = NSAttributedString(string:value,attributes:attrs)
            let setter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:rect,transform:nil),nil)
            guard CTFrameGetVisibleStringRange(frame).length == string.length else { return false }
            CTFrameDraw(frame,context); return true
        }
        guard text(q.company.isEmpty ? "TEKLİF" : q.company,rect:CGRect(x:42,y:744,width:511-logoWidth,height:62),font:22,bold:true) else { throw QuoteError.tooLong }
        context.setStrokeColor(CGColor(gray:0.75,alpha:1)); context.setLineWidth(0.5); context.move(to:CGPoint(x:42,y:732)); context.addLine(to:CGPoint(x:553,y:732)); context.strokePath()
        // Measure every row, then choose a legible font that fits one page. Never truncate customer or cost data.
        var fitted = false
        for font: CGFloat in [11,10,9,8] {
            var heights: [CGFloat] = []
            for (label,value) in lines {
                let v = value.isEmpty ? "—" : value
                let a = NSAttributedString(string:v,attributes:[.font:NSFont.systemFont(ofSize:font)])
                let h = a.boundingRect(with:CGSize(width:350,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading]).height
                let l = NSAttributedString(string:label,attributes:[.font:NSFont.boldSystemFont(ofSize:font)]).boundingRect(with:CGSize(width:145,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading]).height
                heights.append(max(22,max(h,l)+10))
            }
            guard heights.reduce(0,+) <= 665 else { continue }
            var y: CGFloat = 718
            for (index,pair) in lines.enumerated() {
                let height = heights[index]; y -= height
                guard text(pair.0,rect:CGRect(x:42,y:y,width:145,height:height-4),font:font,bold:true), text(pair.1.isEmpty ? "—" : pair.1,rect:CGRect(x:200,y:y,width:353,height:height-4),font:font) else { throw QuoteError.tooLong }
            }
            fitted = true; break
        }
        guard fitted else { throw QuoteError.tooLong }
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to:url,options:.atomic)
    }
    public enum QuoteError: LocalizedError { case tooLong
        public var errorDescription: String? { "Teklif tek sayfaya sığmıyor. Firma adı, not veya maliyet dökümünü kısaltın." }
    }
}
