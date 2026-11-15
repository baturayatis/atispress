import Foundation
import CoreGraphics
import ImpositionCore

public struct PreparedProduct:Sendable {
    public var number:Int
    public var front:Int
    public var back:Int?
}
public enum PDFSourcePreparation {
    public static func products(_ split:PageSplitSettings) -> [PreparedProduct] {
        var next=1
        return Set(split.cells.compactMap(\.product)).sorted().map { product in
            let back=split.cells.contains{$0.product==product && $0.side == .back}
            let result=PreparedProduct(number:product,front:next,back:back ? next+1:nil)
            next+=back ? 2:1;return result
        }
    }
    public static func split(source:URL,destination:URL,settings:PageSplitSettings) throws {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {throw PDFExportError.sourceOverwrite}
        guard let document=CGPDFDocument(source as CFURL),document.numberOfPages==1,let page=document.page(at:1) else {throw SourcePreparationError.unsupportedSource}
        let trim=page.getBoxRect(.trimBox),rotated=abs(page.rotationAngle%180)==90,pt=PDFPreviewDrawing.pointsPerMM
        let size=Size((rotated ? trim.height:trim.width)/pt,(rotated ? trim.width:trim.height)/pt)
        if let message=settings.validation(size:size) {throw SourcePreparationError.invalidGrid(message)}
        let cells=settings.rectangles(size:size)
        var media=CGRect(x:0,y:0,width:100,height:100)
        guard let consumer=CGDataConsumer(url:destination as CFURL),let ctx=CGContext(consumer:consumer,mediaBox:&media,nil) else {throw PDFReadError.unreadable}
        defer {ctx.closePDF()}
        for product in products(settings) {
            for side in [SideKind.front,.back] {
                guard let index=settings.cells.firstIndex(where:{$0.product==product.number && $0.side==side}) else {continue}
                let cell=cells[index],inner=settings.trim(in:cell)
                // PDF boxes are emitted as decimal points. Canonical 0.1 µm
                // cell metadata prevents equal paired trims differing by ulps.
                func canonical(_ v:Double) -> Double {(v*10_000).rounded()/10_000}
                let cw=canonical(cell.size.width),ch=canonical(cell.size.height),tw=canonical(inner.size.width),th=canonical(inner.size.height)
                var box=CGRect(x:0,y:0,width:cw*pt,height:ch*pt)
                var cut=CGRect(x:canonical(inner.origin.x-cell.origin.x)*pt,y:canonical(inner.origin.y-cell.origin.y)*pt,width:tw*pt,height:th*pt)
                let boxData=Data(bytes:&box,count:MemoryLayout<CGRect>.size),trimData=Data(bytes:&cut,count:MemoryLayout<CGRect>.size)
                ctx.beginPDFPage([kCGPDFContextMediaBox:boxData,kCGPDFContextBleedBox:boxData,kCGPDFContextTrimBox:trimData] as CFDictionary)
                ctx.saveGState();ctx.clip(to:box)
                ctx.translateBy(x:-cell.origin.x*pt,y:-cell.origin.y*pt)
                ctx.concatenate(page.getDrawingTransform(.trimBox,rect:CGRect(x:0,y:0,width:size.width*pt,height:size.height*pt),rotate:0,preserveAspectRatio:true))
                ctx.drawPDFPage(page)
                ctx.restoreGState();ctx.endPDFPage()
            }
        }
    }
}
