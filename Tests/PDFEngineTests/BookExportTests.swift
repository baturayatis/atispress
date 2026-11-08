import XCTest
import CoreGraphics
import CoreText
import PDFKit
import ImpositionCore
import PDFEngine

final class BookExportTests: XCTestCase {
    private let unit = 72.0/25.4
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    private func fixture(_ url: URL,count: Int,size: Size,prefix: String = "SRC") throws {
        var box = CGRect(x:0,y:0,width:size.width*unit,height:size.height*unit)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&box,nil))
        for i in 1...count {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(colorSpace:CGColorSpaceCreateDeviceCMYK(),components:[0,0,0,1,1])!)
            let text = String(format:"%@%02d",prefix,i)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,12,nil)]))
            context.textMatrix = .identity; context.textPosition = CGPoint(x:5*unit,y:20*unit); CTLineDraw(line,context)
            context.endPDFPage()
        }
        context.closePDF()
    }
    private static func images(_ dictionary: CGPDFDictionaryRef?) -> Int {
        guard let dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?,objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources),let resources,CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects else { return 0 }
        var count = 0
        withUnsafeMutablePointer(to:&count) { pointer in
            CGPDFDictionaryApplyFunction(objects,{ _,object,info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object,.stream,&stream),let stream,let d = CGPDFStreamGetDictionary(stream) else { return }
                var type: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(d,"Subtype",&type),let type { info!.assumingMemoryBound(to:Int.self).pointee += String(cString:type)=="Image" ? 1 : BookExportTests.images(d) }
            },pointer)
        }
        return count
    }
    func testCreepMovesExportedVectorTextExactlyAsPreviewPlanAndKeepsCoversIndependent() async throws {
        let folder = try folder(),url = folder.appendingPathComponent("book.pdf")
        try fixture(url,count:20,size:Size(50,70)); let source = try await PDFSource.open(url)
        var p = Project(pages:source.pages.map(\.sourcePage),binding:.saddleStitch,sheet:SheetSpec(size:Size(117,87),orientation:.landscape))
        var book = BookSettings(); book.interiorPaper.microns = 1000; book.coverPaper.microns = 500; book.creepEnabled = true; p.book = book
        p.settings.generatedBleed = GeneratedBleedSettings(enabled:true,method:.solidColor,color:.cmyk(0,0,0,0))
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertEqual(plan.sheets.count,5)
        let out = folder.appendingPathComponent("out.pdf"),result = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(out),marks:.none)
        XCTAssertEqual(result.pageCount,10)
        let pdf = try XCTUnwrap(PDFDocument(url:out)),cg = try XCTUnwrap(CGPDFDocument(out as CFURL))
        for (index,sheet) in plan.sheets.enumerated() {
            for (face,side) in [(0,sheet.front),(1,sheet.back)] {
                let page = try XCTUnwrap(pdf.page(at:index*2+face)),text = page.string ?? ""
                for slot in side.slots {
                    guard let number = slot.sourcePageNumber else { continue }
                    let label = String(format:"SRC%02d",number),range = (text as NSString).range(of:label)
                    XCTAssertNotEqual(range.location,NSNotFound)
                    guard range.location != NSNotFound else { continue }
                    let bounds = try XCTUnwrap(page.selection(for:range)).bounds(for:page)
                    XCTAssertEqual(bounds.minX,(slot.x+5+slot.artworkOffset.x)*unit,accuracy:1.5)
                    if sheet.bookInfo?.section == .cover { XCTAssertEqual(slot.artworkOffset,Point(0,0)) }
                }
                XCTAssertFalse(text.contains("Sırt")); XCTAssertFalse(text.contains("İç sayfalar"))
                XCTAssertEqual(Self.images(cg.page(at:index*2+face+1)?.dictionary),0)
            }
        }
    }
    func testSeparateCoverSpreadRemainsVectorAtNativeSizeAndInfoStripUsesSection() async throws {
        let folder = try folder(),insideURL = folder.appendingPathComponent("inside.pdf"),coverURL = folder.appendingPathComponent("cover.pdf")
        try fixture(insideURL,count:8,size:Size(50,70)); try fixture(coverURL,count:2,size:Size(115.48,70),prefix:"COVER")
        let inside = try await PDFSource.open(insideURL),cover = try await PDFSource.open(coverURL)
        let combined = try await PDFSource.combine([inside,cover],displayName:"Kitap ve kapak")
        var p = Project(pages:combined.pages.map(\.sourcePage),binding:.perfectBound,sheet:SheetSpec(preset:.cm50x70))
        p.settings.signatureSize = .eight
        var book = BookSettings(); book.interiorPaper.microns = 120; book.coverPaper.microns = 250; book.leftFlap = 10; book.rightFlap = 5
        book.coverSourceID = UUID(); book.coverPDFPages = [9,10]; book.auxiliaryPages = [9,10]; book.coverArtwork = .spread
        p.book = book; p.coverMode = .separate
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertFalse(plan.issues.contains { $0.message.contains("hesaplanan açılım") })
        let coverSheet = try XCTUnwrap(plan.sheets.first { $0.bookInfo?.section == .cover })
        XCTAssertEqual(try XCTUnwrap(coverSheet.bookInfo?.spine),0.48,accuracy:0.000001)
        XCTAssertEqual(try XCTUnwrap(coverSheet.bookInfo?.spreadSize.width),115.48,accuracy:0.001)
        XCTAssertTrue(PDFSheetInfoContext(jobName:"Kitap",sheetNumber:1,totalSheets:plan.totalPressSheets,side:.front).text(settings:SheetInfoSettings(),sheet:coverSheet).contains("Kapak"))
        let out = folder.appendingPathComponent("vector.pdf")
        let result = try PDFExporter.export(plan:plan,source:combined,destination:.singlePDF(out),marks:.none)
        let pdf = try XCTUnwrap(PDFDocument(url:out)),cg = try XCTUnwrap(CGPDFDocument(out as CFURL))
        XCTAssertEqual(result.sheetCount,plan.totalPressSheets)
        let text = pdf.string ?? ""; XCTAssertTrue(text.contains("COVER01")); XCTAssertTrue(text.contains("COVER02"))
        for i in 1...cg.numberOfPages { XCTAssertEqual(Self.images(cg.page(at:i)?.dictionary),0) }
        for i in 0..<pdf.pageCount { XCTAssertEqual(try XCTUnwrap(pdf.page(at:i)).bounds(for:.mediaBox).width,plan.sheets[i/2].size.width*unit,accuracy:0.01) }
    }
    func testSewnFourPage106WithSeparateCoverAndEveryBlankModeExportsPlannedVectorFaces() async throws {
        let folder = try folder(),bodyURL = folder.appendingPathComponent("inside106.pdf"),coverURL = folder.appendingPathComponent("cover4.pdf")
        try fixture(bodyURL,count:106,size:Size(148,210),prefix:"BODY")
        try fixture(coverURL,count:4,size:Size(148,210),prefix:"COVER")
        let body = try await PDFSource.open(bodyURL),cover = try await PDFSource.open(coverURL),source = try await PDFSource.combine([body,cover])
        var p = Project(pages:source.pages.map(\.sourcePage),binding:.sewn,sheet:SheetSpec(preset:.a4,orientation:.landscape))
        p.settings.signatureSize = .four; p.settings.bleed = 0; p.settings.cropMarkLength = 0; p.settings.cropMarkOffset = 3.5
        var book = BookSettings(); book.coverSourceID = UUID(); book.coverPDFPages = Array(107...110); book.auxiliaryPages = book.coverPDFPages
        p.book = book; p.coverMode = .separate
        for mode in [BlankPlacement.Mode.end,.start,.manual] {
            var setting = BlankPlacement(); setting.mode = mode; setting.positions = [1,55]; p.blankPlacement = setting
            let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport,plan.issues.map(\.message).joined(separator:"\n"))
            XCTAssertEqual(plan.signatureCount,27); XCTAssertEqual(plan.addedBlankPages,2)
            let output = folder.appendingPathComponent("four-\(mode).pdf")
            let result = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(output),marks:.none)
            XCTAssertEqual(result.pageCount,56); XCTAssertEqual(result.sheetCount,28)
            let pdf = try XCTUnwrap(PDFDocument(url:output)),cg = try XCTUnwrap(CGPDFDocument(output as CFURL))
            for (index,sheet) in plan.sheets.enumerated() {
                for (face,side) in [(0,sheet.front),(1,sheet.back)] {
                    let page = try XCTUnwrap(pdf.page(at:index*2+face)),text = page.string ?? ""
                    for slot in side.slots {
                        guard let n = slot.sourcePageNumber else { continue }
                        let label = n<=106 ? String(format:"BODY%02d",n) : String(format:"COVER%02d",n-106)
                        XCTAssertTrue(text.contains(label),"Missing \(label) in form \(index+1)")
                    }
                    XCTAssertFalse(text.contains("Boş"),"Blank-position proof labels must not enter artwork")
                    XCTAssertEqual(page.bounds(for:.mediaBox).width,297*unit,accuracy:0.01)
                    XCTAssertEqual(page.bounds(for:.mediaBox).height,210*unit,accuracy:0.01)
                    XCTAssertEqual(Self.images(cg.page(at:index*2+face+1)?.dictionary),0)
                }
            }
        }
    }

}
