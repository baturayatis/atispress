import XCTest
import PDFKit
import CoreText
import ImpositionCore
import PDFEngine

final class LeafExportTests: XCTestCase {
    private let unit = PDFPreviewDrawing.pointsPerMM
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func source(_ folder: URL,count: Int) async throws -> PDFSource {
        let url = folder.appendingPathComponent("source.pdf")
        var box = CGRect(x:0,y:0,width:40*unit,height:60*unit)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for number in 1...count {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray:0.8,alpha:1)); context.fill(box)
            let font = CTFontCreateWithName("Helvetica" as CFString,8,nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:String(format:"PAGE-%03d;",number),attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
            context.textPosition = CGPoint(x:5*unit,y:20*unit); CTLineDraw(line,context); context.endPDFPage()
        }
        context.closePDF(); return try await PDFSource.open(url)
    }
    private func project(_ source: PDFSource,turn: TurnMethod = .sheetwise) -> Project {
        var p = Project(pages:source.pages.map(\.sourcePage),binding:.spiral,
            sheet:SheetSpec(size:Size(200,200),margins:Insets(left:20,right:20,top:20,bottom:20)),
            settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0,safeAreaInset:2,turnMethod:turn),
            stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,allowRotation:false))
        p.blockAlignment = .center; p.exportMarks = .none; p.leafSettings.allowance = 5
        return p
    }
    func testExportTextOnEachPressFaceMatchesCutStackPlanForAllTurnStyles() async throws {
        let folder = try folder(),source = try await source(folder,count:18)
        for turn in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            var p = project(source,turn:turn); p.binding = .wireO
            let plan = ImpositionPlanner.plan(p)
            let output = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(folder.appendingPathComponent("\(turn).pdf")),marks:.none)
            let pdf = try XCTUnwrap(PDFDocument(url:output.files[0]))
            XCTAssertEqual(pdf.pageCount,plan.sheets.count*2)
            for (index,sheet) in plan.sheets.enumerated() {
                for (face,side) in [sheet.front,sheet.back].enumerated() {
                    let text = pdf.page(at:index*2+face)?.string ?? ""
                    for number in 1...18 {
                        XCTAssertEqual(text.contains(String(format:"PAGE-%03d;",number)),side.slots.contains { $0.sourcePageNumber==number },"\(turn), sheet \(index), face \(face), page \(number)")
                    }
                }
            }
        }
    }
    func testPunchesAreVectorCirclesSharedByPreviewAndExportAndOddLeafRetainsBlankBack() async throws {
        let folder = try folder(),source = try await source(folder,count:1)
        var p = project(source); p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        p.leafSettings.holes = true; p.leafSettings.pitch = 12; p.leafSettings.diameter = 3; p.leafSettings.offset = 6
        let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first),mark = try XCTUnwrap(sheet.front.punchMarks.first)
        let output = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(folder.appendingPathComponent("holes.pdf")),marks:.none)
        let document = try XCTUnwrap(CGPDFDocument(output.files[0] as CFURL))
        XCTAssertEqual(output.pageCount,2,"An odd leaf's blank reverse remains part of duplex output")
        XCTAssertEqual(plan.addedBlankPages,1)
        let bytes = try Data(contentsOf:output.files[0]),text = String(decoding:bytes,as:UTF8.self)
        XCTAssertNil(text.range(of:"/Subtype\\s*/Image\\b",options:.regularExpression),"Vector source plus punch circles must not add image XObjects")
        func bitmap() throws -> CGContext {
            let c = try XCTUnwrap(CGContext(data:nil,width:1200,height:1200,bitsPerComponent:8,bytesPerRow:4800,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:1200,height:1200)); c.scaleBy(x:6,y:6); return c
        }
        let preview = try bitmap(),exported = try bitmap(),off = try bitmap()
        var options = PDFRenderOptions.artworkOnly; options.punch = true
        let original = try XCTUnwrap(CGPDFDocument(source.url as CFURL))
        try PDFPlanRenderer.drawSide(sheet.front,sheet:sheet,document:original,in:preview,sheetIndex:0,kind:.front,repetition:0,options:options)
        try PDFPlanRenderer.drawSide(sheet.front,sheet:sheet,document:original,in:off,sheetIndex:0,kind:.front,repetition:0,options:.artworkOnly)
        exported.scaleBy(x:1/unit,y:1/unit); exported.drawPDFPage(try XCTUnwrap(document.page(at:1)))
        let rect = mark.bounds
        var differences = 0,dark = 0
        for y in Int((rect.origin.y-0.5)*6)..<Int((rect.origin.y+rect.size.height+0.5)*6) {
            for x in Int((rect.origin.x-0.5)*6)..<Int((rect.origin.x+rect.size.width+0.5)*6) {
                let index = y*4800+x*4
                let a = preview.data!.assumingMemoryBound(to:UInt8.self)[index]
                let b = exported.data!.assumingMemoryBound(to:UInt8.self)[index]
                let c = off.data!.assumingMemoryBound(to:UInt8.self)[index]
                XCTAssertEqual(Int(a),Int(b),accuracy:3)
                if a<200 { dark += 1 }; if a != c { differences += 1 }
            }
        }
        XCTAssertGreaterThan(dark,0); XCTAssertGreaterThan(differences,0)
    }
}
