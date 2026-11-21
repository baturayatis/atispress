import XCTest
import CoreGraphics
import PDFKit
import ImpositionCore
import PDFEngine

final class SpinePDFTests: XCTestCase {
    private let unit = PDFPreviewDrawing.pointsPerMM

    func testTextLayoutFitsTurkishGlyphsAndMeasuresPhysicalOverflow() throws {
        let trim = CGRect(x:0,y:0,width:6,height:90)
        var block = SpineContent.TextBlock()
        block.text = "İŞİ ĞÜÇ ÖĞÜŞ"
        block.bold = true
        block.italic = true
        block.size = 100
        let overflow = try XCTUnwrap(PDFSpine.layout(block,at:.middle,in:trim))
        XCTAssertGreaterThan(overflow.overflow.width,0)
        XCTAssertGreaterThan(overflow.overflow.height,0)
        XCTAssertTrue(PDFSpine.warning(block,at:.middle,in:trim)?.contains("mm") == true)
        block.autoFit = true
        block.size = 12
        let fit = try XCTUnwrap(PDFSpine.layout(block,at:.middle,in:trim))
        XCTAssertEqual(fit.bounds.midX,3,accuracy:0.0001)
        XCTAssertEqual(fit.bounds.midY,45,accuracy:0.0001)
        XCTAssertEqual(fit.overflow,.zero)
        block.autoFit = false
        block.size = fit.size*0.55
        block.alignment = .start
        block.x = 0.5; block.y = 1
        let down = try XCTUnwrap(PDFSpine.layout(block,at:.middle,in:trim))
        XCTAssertEqual(down.bounds.maxY,61,accuracy:0.0001)
        block.bottomUp = true
        let up = try XCTUnwrap(PDFSpine.layout(block,at:.middle,in:trim))
        XCTAssertEqual(up.bounds.minY,31,accuracy:0.0001)
        XCTAssertEqual(up.bounds.midX,3.5,accuracy:0.0001)
    }

    func testSharedSpineRenderingVectorColorBleedEdgeSamplesAndFontEmbedding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("source.pdf")
        var box = CGRect(x:0,y:0,width:50*unit,height:70*unit)
        let writer = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for i in 1...10 {
            writer.beginPDFPage(nil)
            writer.setFillColor(PDFSpine.color(i == 1 ? .cmyk(1,0,0,0) : .cmyk(0,1,0,0)))
            writer.fill(box)
            writer.endPDFPage()
        }
        writer.closePDF()
        let source = try await PDFSource.open(url)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        var input = Project(pages:source.pages.map(\.sourcePage),binding:.perfectBound,
                            sheet:SheetSpec(size:Size(160,120),orientation:.landscape))
        input.settings.bleed = 3
        var book = BookSettings()
        book.automaticCover = true
        book.spineWidth = 12
        book.spineContent = SpineContent()
        input.book = book

        for extend in [false,true] {
            input.book?.spineContent?.mode = .color
            input.book?.spineContent?.color = .cmyk(0,0,0,1)
            input.book?.spineContent?.extendEdges = extend
            input.book?.spineContent?.foldMarks = true
            let plan = ImpositionPlanner.plan(input)
            let sheet = try XCTUnwrap(plan.sheets.first)
            let slot = try XCTUnwrap(sheet.front.slots.first { $0.spineArtwork != nil })
            XCTAssertEqual(PDFExportMarkRenderer.geometry(side:sheet.front,sheet:sheet,settings:.none)
                .segments.filter { $0.kind == .spineFold }.count,4)
            let bitmap = try XCTUnwrap(CGContext(data:nil,width:640,height:480,bitsPerComponent:8,bytesPerRow:0,
                                                 space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.scaleBy(x:4,y:4)
            try PDFPlanRenderer.drawSide(sheet.front,sheet:sheet,document:document,in:bitmap,
                                         sheetIndex:0,kind:.front,repetition:0,options:.artworkOnly)
            let out = folder.appendingPathComponent("color-\(extend).pdf")
            _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:.none)
            let exported = try XCTUnwrap(CGPDFDocument(out as CFURL)?.page(at:1))
            let pdfBitmap = try XCTUnwrap(CGContext(data:nil,width:640,height:480,bitsPerComponent:8,bytesPerRow:0,
                                                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            pdfBitmap.scaleBy(x:4/unit,y:4/unit)
            pdfBitmap.drawPDFPage(exported)
            func sample(_ context: CGContext,_ local: CGPoint) throws -> [UInt8] {
                let point = local.applying(PDFPreviewDrawing.slotTransform(slot))
                let index = (context.height-1-Int(point.y*4))*context.bytesPerRow+Int(point.x*4)*4
                let data = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
                return Array(UnsafeBufferPointer(start:data+index,count:4))
            }
            let left = try sample(bitmap,CGPoint(x:3,y:35))
            let right = try sample(bitmap,CGPoint(x:9,y:35))
            XCTAssertEqual(left == right,!extend)
            for x in [3.0,9] {
                let trim = try sample(bitmap,CGPoint(x:x,y:35))
                for y in [-1.0,35,71] {
                    let local = CGPoint(x:x,y:y)
                    XCTAssertEqual(try sample(bitmap,local),trim)
                    XCTAssertEqual(try sample(pdfBitmap,local),trim)
                }
            }
            XCTAssertNil(try Data(contentsOf:out).range(of:Data("/Subtype /Image".utf8)))
        }

        var block = SpineContent.TextBlock()
        block.text = "İŞ ĞÜÇ Ö"
        block.size = 70
        input.book?.spineContent?.mode = .text
        input.book?.spineContent?.blocks[.middle] = block
        let invalid = ImpositionPlanner.plan(input)
        XCTAssertFalse(PDFSpine.issues(in:invalid).isEmpty)
        XCTAssertThrowsError(try PDFExporter.export(plan:invalid,source:source,
                                                       destination:.singlePDF(folder.appendingPathComponent("invalid.pdf"))))
        block.autoFit = true
        for outlines in [true,false] {
            block.outlines = outlines
            input.book?.spineContent?.blocks[.middle] = block
            let plan = ImpositionPlanner.plan(input)
            XCTAssertTrue(PDFSpine.issues(in:plan).isEmpty)
            let out = folder.appendingPathComponent("text-\(outlines).pdf")
            _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:.none)
            let data = try Data(contentsOf:out)
            let token = Data("/FontFile".utf8)
            XCTAssertEqual(data.range(of:token) != nil,!outlines)
            let text = PDFDocument(url:out)?.page(at:0)?.string ?? ""
            XCTAssertEqual(text.contains("ĞÜÇ"),!outlines)
        }
    }
}
