import Foundation
import CoreGraphics
import ImpositionCore
import PDFEngine

struct ExportVerification:Sendable {
    var differences:[String] = []
    var passed:Bool { differences.isEmpty }
    var label:String { passed ? "Çıktı plana uygun" : differences.joined(separator:"\n") }
    /// Reopen the published files. Check dimensions and artwork at each planned trim slot.
    /// Expected artwork is drawn directly from the immutable plan, independent of file pagination.
    static func check(files:[URL],plan:ImpositionPlan,source:PDFSource,marks:ExportMarks,includeBlankBacks:Bool) throws -> Self {
        var result = Self()
        let docs = try files.map { url -> CGPDFDocument in guard let doc = CGPDFDocument(url as CFURL) else { throw PDFReadError.unreadable }; return doc }
        let keep = plan.hasBackContent && includeBlankBacks
        let expectedCount = plan.sheets.reduce(0) { $0+$1.repeatCount*($1.hasContent(on:.back) || keep ? 2 : 1) }
        let actualCount = docs.reduce(0) { $0+$1.numberOfPages }
        if actualCount != expectedCount { result.differences.append("Sayfa sayısı: beklenen \(expectedCount), bulunan \(actualCount).") }
        guard let sourceDoc = CGPDFDocument(source.url as CFURL) else { throw PDFReadError.unreadable }
        var fileIndex = 0,pageIndex = 1,physicalPage = 0
        for (sheetIndex,sheet) in plan.sheets.enumerated() {
            for repetition in 0..<sheet.repeatCount {
                for kind in (sheet.hasContent(on:.back) || keep ? [SideKind.front,.back] : [.front]) {
                    try Task.checkCancellation()
                    physicalPage += 1
                    while fileIndex < docs.count && pageIndex > docs[fileIndex].numberOfPages { fileIndex += 1; pageIndex = 1 }
                    guard fileIndex < docs.count,let actual = docs[fileIndex].page(at:pageIndex) else { continue }
                    pageIndex += 1
                    let size = CGSize(width:sheet.size.width*72/25.4,height:sheet.size.height*72/25.4)
                    let box = actual.getBoxRect(.mediaBox)
                    if abs(box.width-size.width)>0.05 || abs(box.height-size.height)>0.05 || abs(box.minX)>0.05 || abs(box.minY)>0.05 || actual.rotationAngle != 0 {
                        result.differences.append("Sayfa \(physicalPage): tabaka ölçüsü veya yönü plandan farklı."); continue
                    }
                    let side = kind == .front ? sheet.front : sheet.back
                    let data = NSMutableData()
                    var media = CGRect(origin:.zero,size:size)
                    guard let consumer = CGDataConsumer(data:data),let context = CGContext(consumer:consumer,mediaBox:&media,nil) else { throw PDFExportError.cannotCreatePDF }
                    context.beginPDFPage(nil); context.scaleBy(x:72/25.4,y:72/25.4)
                    let generated:[any PDFSlotOverlay] = plan.generatedBleed.enabled || !sheet.generatedBleedByJob.isEmpty ? [GeneratedBleedOverlay(settings:plan.generatedBleed,cache:source.edgeSamples,jobSettings:sheet.generatedBleedByJob)] : []
                    try PDFPlanRenderer.drawSide(side,sheet:sheet,document:sourceDoc,in:context,sheetIndex:sheetIndex,kind:kind,repetition:repetition,options:.artworkOnly,overlays:generated,tone:plan.tone,edgeSamples:source.edgeSamples)
                    PDFExportMarkRenderer.draw(side:side,sheet:sheet,in:context,settings:marks,info:"",kind:kind)
                    context.endPDFPage(); context.closePDF()
                    guard let provider = CGDataProvider(data:data),let expected = CGPDFDocument(provider)?.page(at:1) else { throw PDFExportError.cannotCreatePDF }
                    let scale = min(2,1500/max(sheet.size.width,sheet.size.height)) // pixels/mm, bounded memory
                    func raster(_ page:CGPDFPage) throws -> Data {
                        let width = max(1,Int(ceil(sheet.size.width*scale))),height = max(1,Int(ceil(sheet.size.height*scale)))
                        guard let bitmap = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFExportError.cannotCreatePDF }
                        bitmap.setFillColor(CGColor(gray:1,alpha:1)); bitmap.fill(CGRect(x:0,y:0,width:width,height:height))
                        bitmap.scaleBy(x:scale*25.4/72,y:scale*25.4/72); bitmap.drawPDFPage(page)
                        return Data(bytes:bitmap.data!,count:width*height*4)
                    }
                    let a = try raster(actual),b = try raster(expected),width = max(1,Int(ceil(sheet.size.width*scale))),height = max(1,Int(ceil(sheet.size.height*scale)))
                    for (index,slot) in side.slots.enumerated() where slot.sourcePageNumber != nil || slot.spineArtwork != nil {
                        let x0 = max(0,Int(ceil((slot.x+0.3)*scale))),x1 = min(width,Int(floor((slot.x+slot.size.width-0.3)*scale)))
                        let y0 = max(0,Int(ceil((slot.y+0.3)*scale))),y1 = min(height,Int(floor((slot.y+slot.size.height-0.3)*scale)))
                        guard x0 < x1,y0 < y1 else { continue }
                        var changed = 0,total = 0
                        for y in y0..<y1 { for x in x0..<x1 { let offset = (y*width+x)*4; total += 1
                            if (0..<3).contains(where:{ abs(Int(a[offset+$0])-Int(b[offset+$0]))>16 }) { changed += 1 }
                        } }
                        if Double(changed)/Double(max(1,total))>0.01 { result.differences.append("Sayfa \(physicalPage) · ürün \(index+1): konum veya içerik plandan farklı.") }
                    }
                }
            }
        }
        return result
    }
}
