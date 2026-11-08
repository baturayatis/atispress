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
    func testBindingPageTransformsKeepVectorTextAndPreviewMatchesExportOnBothFaces() async throws {
        let folder = try folder(),source = try await source(folder,count:2)
        for behavior in [BindingAllowanceBehavior.preserve,.shrink,.shift] {
            var p = project(source); p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
            p.leafSettings.allowance = 12; p.leafSettings.behavior = behavior
            let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
            let output = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(folder.appendingPathComponent("placement-\(behavior).pdf")),marks:.none)
            let pdf = try XCTUnwrap(PDFDocument(url:output.files[0]))
            let cg = try XCTUnwrap(CGPDFDocument(output.files[0] as CFURL)),original = try XCTUnwrap(CGPDFDocument(source.url as CFURL))
            for (face,side) in [sheet.front,sheet.back].enumerated() {
                let slot = try XCTUnwrap(side.slots.first),page = try XCTUnwrap(pdf.page(at:face))
                let text = page.string ?? "",range = (text as NSString).range(of:String(format:"PAGE-%03d;",face+1))
                XCTAssertNotEqual(range.location,NSNotFound)
                let selection = try XCTUnwrap(page.selection(for:range))
                let bounds = selection.bounds(for:page)
                XCTAssertEqual(bounds.minX,(slot.x+slot.bindingTranslation.x+5*slot.bindingScale)*unit,accuracy:1.2)
                let attributes = try XCTUnwrap(page.attributedString)
                var fontSizes: [CGFloat] = []
                attributes.enumerateAttribute(.font,in:NSRange(location:0,length:attributes.length)) { value,_,_ in
                    if let font = value as? NSFont { fontSizes.append(font.pointSize) }
                }
                XCTAssertFalse(fontSizes.isEmpty)
                XCTAssertTrue(fontSizes.allSatisfy { abs($0-8*slot.bindingScale)<0.05 })
                func bitmap() throws -> CGContext {
                    let c = try XCTUnwrap(CGContext(data:nil,width:800,height:800,bitsPerComponent:8,bytesPerRow:3200,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                    c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:800,height:800)); c.scaleBy(x:4,y:4); return c
                }
                let preview = try bitmap(),exported = try bitmap()
                try PDFPlanRenderer.drawSide(side,sheet:sheet,document:original,in:preview,sheetIndex:0,kind:face==0 ? .front : .back,repetition:0,options:.artworkOnly)
                exported.scaleBy(x:1/unit,y:1/unit); exported.drawPDFPage(try XCTUnwrap(cg.page(at:face+1)))
                // Compare interior page pixels, including the moved/shrunken edge.
                let a = preview.data!.assumingMemoryBound(to:UInt8.self),b = exported.data!.assumingMemoryBound(to:UInt8.self)
                var mismatch = 0,samples = 0
                for y in stride(from:100,to:700,by:2) { for x in stride(from:100,to:700,by:2) {
                    let i = y*3200+x*4; if abs(Int(a[i])-Int(b[i]))>20 { mismatch += 1 }; samples += 1
                } }
                XCTAssertLessThan(Double(mismatch)/Double(samples),0.005)
                // Native raster fallback must use the identical placement transform.
                _ = await source.image(page:face+1,pixels:512)
                let raster = try XCTUnwrap(source.cachedRaster(page:face+1,pixels:512))
                let fallback = try bitmap()
                try PDFPlanRenderer.drawSlot(slot,page:original.page(at:face+1),in:fallback,reference:SlotReference(sheet:0,side:face==0 ? .front : .back,slot:0),raster:raster)
                let r = slot.artworkClip!
                let cx = Int((r.origin.x+r.size.width/2)*4),cy = Int((r.origin.y+r.size.height/2)*4)
                XCTAssertLessThan(fallback.data!.assumingMemoryBound(to:UInt8.self)[cy*3200+cx*4],240)
                if behavior == .shift {
                    let beyond = Int((slot.bindingTranslation.x>0 ? r.origin.x+r.size.width-1 : r.origin.x+1)*4)
                    XCTAssertLessThan(a[cy*3200+beyond*4],240,"Shifted page must remain visible past its original trim")
                    XCTAssertLessThan(b[cy*3200+beyond*4],240)
                }
            }
            let bytes = String(decoding:try Data(contentsOf:output.files[0]),as:UTF8.self)
            XCTAssertNil(bytes.range(of:"/Subtype\\s*/Image\\b",options:.regularExpression))
        }
    }

    func testShrinkingDoesNotAllowProductionMarksInProductWhiteArea() {
        var slot = Slot(sourcePageNumber:1,origin:Point(0,0),size:Size(200,160))
        slot.bindingEdge = .left; slot.bindingAllowance = 50
        BindingAllowanceLayout.apply(to:&slot,inset:5,behavior:.shrink)
        let side = Side(slots:[slot],marks:[Mark(kind:.crop,start:Point(5,10),end:Point(10,10))])
        let sheet = Sheet(size:Size(200,160),front:side,back:Side())
        var marks = ExportMarks(); marks.colorBar = true; marks.registrationTargets = true
        XCTAssertTrue(PDFExportMarkRenderer.geometry(side:side,sheet:sheet,settings:marks).segments.isEmpty)
        XCTAssertNil(PDFSheetInfo.placement(text:"İş",side:side,sheet:sheet,marks:marks))
        let controls = PDFColorControlRenderer.geometry(sheet:sheet,settings:marks)
        XCTAssertTrue(controls.patches.isEmpty); XCTAssertTrue(controls.targets.isEmpty)
        XCTAssertFalse(controls.warnings.isEmpty)
    }

}
