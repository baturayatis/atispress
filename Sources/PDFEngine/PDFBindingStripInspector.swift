import Foundation
import CoreGraphics
import ImpositionCore

public final class PDFBindingStripCache: @unchecked Sendable {
    fileprivate let values = NSCache<NSString,NSNumber>()
    public init() { values.countLimit = 4096 }
}

/// Best-effort bounded RGB strip rendering, used only for warnings. Page artwork
/// in preview/export is still the original vector PDF. Each source owns its cache.
public enum PDFBindingStripInspector {
    public static func warnings(plan: ImpositionPlan,url: URL,cache: PDFBindingStripCache = PDFBindingStripCache()) -> [ValidationIssue] {
        var slots: [Slot] = []
        for sheet in plan.sheets {
            for side in [sheet.front,sheet.back] {
                for slot in side.slots {
                    if slot.sourcePageNumber != nil && slot.bindingBehavior == .preserve && slot.bindingAllowance>0 && slot.bindingEdge != nil { slots.append(slot) }
                }
            }
        }
        guard !slots.isEmpty else { return [] }
        let document = CGPDFDocument(url as CFURL)
        var content = Set<Int>(),unknown = Set<Int>(),seen = Set<String>()
        for slot in slots {
            if Task.isCancelled { return [] }
            let number = slot.sourcePageNumber!
            let rect = localStrip(slot)
            let key = "\(number):\(rect.minX):\(rect.minY):\(rect.width):\(rect.height)" as NSString
            guard seen.insert(key as String).inserted else { continue }
            let status: Int
            if let hit = cache.values.object(forKey:key) { status = hit.intValue }
            else {
                status = document?.page(at:number).map { inspect($0,strip:rect,trim:PDFPreviewDrawing.localTrim(slot)) } ?? 2
                cache.values.setObject(NSNumber(value:status),forKey:key)
            }
            if status == 1 { content.insert(number) }
            if status == 2 { unknown.insert(number) }
        }
        func issue(_ pages: Set<Int>,_ text: String) -> ValidationIssue {
            var issue = ValidationIssue(.warning,.bindingAllowance,"\(pages.count) sayfada \(text): \(pages.sorted().map(String.init).joined(separator:", ")).")
            issue.affectedPages = pages.sorted(); return issue
        }
        var result: [ValidationIssue] = []
        if !content.isEmpty { result.append(issue(content,"cilt payı şeridinde beyaz olmayan içerik var (Koru); Küçült/Kaydır veya tasarım düzeltmesiyle kontrol edin")) }
        if !unknown.isEmpty { result.append(issue(unknown,"cilt payı şeridi kontrol edilemedi; baskı öncesi elle kontrol edin")) }
        return result
    }
    public static func localStrip(_ slot: Slot) -> CGRect {
        let a = min(slot.bindingAllowance,(slot.bindingEdge == .left || slot.bindingEdge == .right) ? slot.size.width : slot.size.height)
        let sheet: CGRect
        switch slot.bindingEdge ?? .left {
        case .left: sheet = CGRect(x:slot.x,y:slot.y,width:a,height:slot.size.height)
        case .right: sheet = CGRect(x:slot.x+slot.size.width-a,y:slot.y,width:a,height:slot.size.height)
        case .top: sheet = CGRect(x:slot.x,y:slot.y+slot.size.height-a,width:slot.size.width,height:a)
        case .bottom: sheet = CGRect(x:slot.x,y:slot.y,width:slot.size.width,height:a)
        }
        return sheet.applying(PDFPreviewDrawing.slotTransform(slot).inverted()).offsetBy(dx:-slot.artworkOffset.x,dy:-slot.artworkOffset.y)
    }
    private static func inspect(_ page: CGPDFPage,strip: CGRect,trim: CGRect) -> Int {
        guard strip.width.isFinite,strip.height.isFinite,strip.width>0,strip.height>0 else { return 2 }
        // At most 1024×128 pixels per strip. Very fine/light content can be missed.
        let ratio = min(4,1024/max(strip.width,strip.height),128/min(strip.width,strip.height))
        let w = max(1,Int(ceil(strip.width*ratio))),h = max(1,Int(ceil(strip.height*ratio)))
        guard let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return 2 }
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:w,height:h))
        context.scaleBy(x:Double(w)/strip.width,y:Double(h)/strip.height)
        context.translateBy(x:-strip.minX,y:-strip.minY)
        PDFPreviewDrawing.draw(page,in:context,rect:trim)
        guard let data = context.data?.assumingMemoryBound(to:UInt8.self) else { return 2 }
        var ink = 0
        for i in 0..<(w*h) {
            if min(data[i*4],data[i*4+1],data[i*4+2])<245 { ink += 1; if ink>=3 { return 1 } }
        }
        return 0
    }
}
