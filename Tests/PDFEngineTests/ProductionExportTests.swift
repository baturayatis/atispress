import XCTest
import PDFKit
import ImpositionCore
import PDFEngine

final class ProductionExportTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func source(_ folder: URL,count: Int = 1) async throws -> PDFSource {
        let url = folder.appendingPathComponent("source.pdf")
        var media = CGRect(x: 0,y: 0,width: 20*72/25.4,height: 30*72/25.4)
        let cg = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for _ in 0..<count { cg.beginPDFPage(nil); cg.setFillColor(CGColor(gray: 0.8,alpha: 1)); cg.fill(media); cg.endPDFPage() }
        cg.closePDF()
        return try await PDFSource.open(url)
    }
    private func project(_ source: PDFSource) -> Project {
        Project(pages: source.pages.map(\.sourcePage),sheet: SheetSpec(size: Size(100,100)),
            settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1),
            stepAndRepeat: StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 10))
    }
    func testFireCopiesIncreaseFrontOnlyOutputWithoutAccidentalNumbers() async throws {
        let folder = try directory(), source = try await source(folder)
        for numbered in [false,true] {
            var p = project(source)
            var waste = WasteSettings(); waste.mode = .fixed; waste.fixed = 5; waste.numberCopies = numbered
            p.stepAndRepeat.waste = waste; p.stepAndRepeat.pageLayout = PageLayoutSettings()
            p.serialFields = [SerialField(prefix: "W-",position: Point(3,15))]
            let plan = ImpositionPlanner.plan(p)
            let result = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(folder.appendingPathComponent("waste-\(numbered).pdf")),marks: .none)
            XCTAssertEqual(result.pageCount,4); XCTAssertEqual(result.sheetCount,4)
            let pdf = try XCTUnwrap(PDFDocument(url: result.files[0])),text = pdf.string ?? ""
            for value in 1...(numbered ? 15 : 10) { XCTAssertTrue(text.contains(String(format: "W-%04d",value))) }
            XCTAssertEqual(text.contains("W-0011"),numbered)
            XCTAssertFalse(text.contains("W-0016"))
        }
    }
    func testPageOverridesUseExistingMixedBlankReversePolicy() async throws {
        let folder = try directory(), source = try await source(folder,count: 4)
        var p = project(source); p.stepAndRepeat.quantity = 1
        p.stepAndRepeat.pageLayout = PageLayoutSettings()
        p.stepAndRepeat.pageLayout?.overrides = [PageJobOverride(frontPage: 1,layout: .simplex)]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertEqual(plan.sheets.count,3)
        for include in [true,false] {
            let result = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(folder.appendingPathComponent("mixed-\(include).pdf")),marks: .none,includeBlankBacks: include)
            XCTAssertEqual(result.pageCount,include ? 6 : 4)
        }
    }
    func testInfoStripFitsMarginAvoidsBleedAndMarksAndRejectsFullSheet() throws {
        let slot = Slot(sourcePageNumber: 1,origin: Point(30,30),size: Size(120,100),artworkClip: Rect(x: 27,y: 27,width: 126,height: 106))
        let side = Side(slots: [slot],marks: [Mark(kind: .crop,start: Point(0,3),end: Point(200,3))])
        let sheet = Sheet(size: Size(200,160),front: side,back: Side())
        let placement = try XCTUnwrap(PDFSheetInfo.placement(text: "İş · Tabaka 1 / 2 · Ön · Dijital",side: side,sheet: sheet,marks: ExportMarks()))
        XCTAssertTrue(CGRect(x: 0,y: 0,width: 200,height: 160).contains(placement.bounds))
        XCTAssertFalse(placement.bounds.intersects(CGRect(x: 27,y: 27,width: 126,height: 106)))
        XCTAssertFalse(placement.bounds.intersects(CGRect(x: 0,y: 2.5,width: 200,height: 1)))
        let full = Side(slots: [Slot(sourcePageNumber: 1,origin: Point(0,0),size: Size(200,160))])
        XCTAssertNil(PDFSheetInfo.placement(text: "İş",side: full,sheet: sheet,marks: .none))
        XCTAssertNil(PDFSheetInfo.placement(text: String(repeating: "Long name ",count: 100),side: side,sheet: sheet,marks: .none))
    }
    func testInfoFieldsVectorSixPointTextAndNoRoomWarning() async throws {
        let folder = try directory(), source = try await source(folder)
        var p = project(source); p.sheet.size = Size(220,160); p.sheet.orientation = .landscape
        p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1; p.stepAndRepeat.quantity = 1
        let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
        var marks = ExportMarks.none; marks.sheetInfo = true
        var settings = SheetInfoSettings(); settings.jobName = "Deneme"
        settings.date = false; settings.sheetNumber = false; settings.side = false; settings.sheetSize = false; settings.production = false
        let context = PDFSheetInfoContext(jobName: "source.pdf",sheetNumber: 1,totalSheets: 3,side: .back,production: .offset)
        XCTAssertEqual(context.text(settings: settings,sheet: sheet),"Deneme")
        var all = settings; all.date = true; all.sheetNumber = true; all.side = true; all.sheetSize = true; all.production = true
        let text = context.text(settings: all,sheet: sheet)
        for value in ["Deneme","Tabaka 1 / 3","Arka","220.0×160.0 mm","Ofset"] { XCTAssertTrue(text.contains(value)) }
        let output = try PDFExporter.export(plan: plan,source: source,destination: .singlePDF(folder.appendingPathComponent("info.pdf")),marks: marks,jobName: "source.pdf",sheetInfo: settings)
        XCTAssertFalse(output.notes.contains(PDFSheetInfo.noRoomWarning))
        let pdf = try XCTUnwrap(PDFDocument(url: output.files[0])),page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertTrue(page.string?.contains("Deneme") == true)
        XCTAssertFalse(page.string?.contains("source.pdf") == true)
        let attributed = try XCTUnwrap(page.attributedString)
        var sizes: [CGFloat] = []
        attributed.enumerateAttribute(.font,in: NSRange(location: 0,length: attributed.length)) { value,_,_ in
            if let font = value as? NSFont { sizes.append(font.pointSize) }
        }
        XCTAssertFalse(sizes.isEmpty)
        XCTAssertTrue(sizes.allSatisfy { abs($0-6) < 0.05 },"Info text must be vector 6 pt: \(sizes)")
        let full = Sheet(size: Size(20,30),front: Side(slots: [Slot(sourcePageNumber: 1,origin: Point(0,0),size: Size(20,30))]),back: Side())
        let noRoom = try PDFExporter.export(plan: ImpositionPlan(sheets: [full]),source: source,destination: .singlePDF(folder.appendingPathComponent("no-room.pdf")),marks: marks,sheetInfo: settings)
        XCTAssertTrue(noRoom.notes.contains(PDFSheetInfo.noRoomWarning))
        XCTAssertFalse(PDFDocument(url: noRoom.files[0])?.string?.contains("Deneme") == true)
    }
}
