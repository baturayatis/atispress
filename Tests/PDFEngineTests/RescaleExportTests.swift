import XCTest
import PDFKit
import ImpositionCore
@testable import PDFEngine

final class RescaleExportTests: XCTestCase {
    func testEveryModeExportsVectorsAndMatchesPreviewIncludingGeneratedBleed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("source.pdf"),ppmm = PDFPreviewDrawing.pointsPerMM
        var media = CGRect(x:0,y:0,width:100*ppmm,height:60*ppmm)
        let pdf = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        pdf.beginPDFPage(nil); pdf.scaleBy(x:ppmm,y:ppmm)
        pdf.setFillColor(CGColor(red:0.1,green:0.4,blue:0.8,alpha:1)); pdf.fill(CGRect(x:0,y:0,width:100,height:60))
        pdf.setFillColor(CGColor(gray:0,alpha:1)); pdf.fill(CGRect(x:30,y:20,width:40,height:20))
        pdf.endPDFPage(); pdf.closePDF()
        let source = try await PDFSource.open(url)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        func bitmap() throws -> CGContext {
            let c = try XCTUnwrap(CGContext(data:nil,width:520,height:360,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:520,height:360)); c.scaleBy(x:4,y:4)
            return c
        }
        for mode in RescaleMode.allCases {
            var p = Project(pages:source.pages.map(\.sourcePage),sheet:SheetSpec(size:Size(130,90),margins:Insets(left:10,right:10,top:10,bottom:10)),
                            settings:ImpositionSettings(bleed:3,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:1,rows:1,allowRotation:false,quantity:1))
            p.rescaleJobs = [RescaleJob(pages:[1],settings:RescaleSettings(target:Size(90,50),mode:mode))]
            let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
            let preview = try bitmap()
            try PDFPlanRenderer.drawSide(sheet.front,sheet:sheet,document:document,in:preview,sheetIndex:0,kind:.front,repetition:0,options:.artworkOnly,
                overlays:[GeneratedBleedOverlay(settings:plan.generatedBleed,cache:source.edgeSamples,sampleIfMissing:true)])
            let output = dir.appendingPathComponent("\(mode).pdf")
            _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(output),options:.artworkOnly)
            let result = try XCTUnwrap(CGPDFDocument(output as CFURL)),page = try XCTUnwrap(result.page(at:1)),export = try bitmap()
            export.scaleBy(x:1/ppmm,y:1/ppmm); export.drawPDFPage(page)
            let a = preview.data!.assumingMemoryBound(to:UInt8.self),b = export.data!.assumingMemoryBound(to:UInt8.self)
            var mismatch = 0
            for i in 0..<(preview.bytesPerRow*preview.height) { if abs(Int(a[i])-Int(b[i]))>3 { mismatch += 1 } }
            XCTAssertLessThan(mismatch,520*360/100,"\(mode): preview/export pixel mismatch")
            let data = try Data(contentsOf:output)
            // The established automatic edge method may use one-pixel strips.
            // It must never replace the PDF page with a bitmap.
            let text = String(decoding:data,as:UTF8.self)
            let pattern = #"/Subtype /Image[^>]*"#
            let regex = try NSRegularExpression(pattern:pattern)
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                let image = (text as NSString).substring(with:match.range)
                XCTAssertTrue(image.contains("/Width 1 ") || image.contains("/Height 1 "),image)
            }
            // Exterior bleed is colored, not white, in both renderer paths.
            let slot = try XCTUnwrap(sheet.front.slots.first),x = Int((slot.x-2)*4),y = Int((slot.y+25)*4)
            let offset = (preview.height-1-y)*preview.bytesPerRow+x*4
            XCTAssertLessThan(Int(a[offset]),100)
            XCTAssertGreaterThan(Int(a[offset+2]),150)
        }
    }
}
