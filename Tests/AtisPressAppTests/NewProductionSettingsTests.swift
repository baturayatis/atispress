import XCTest
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class NewProductionSettingsTests: XCTestCase {
    func testScrollGeometrySelectionAndKeyboardBoundsForThousandSheets() {
        let geometry = SheetScrollGeometry(heights:Array(repeating:400,count:1000))
        XCTAssertEqual(geometry.index(at:0),0); XCTAssertEqual(geometry.index(at:399),0)
        XCTAssertEqual(geometry.index(at:400),1); XCTAssertEqual(geometry.index(at:399999),999)
        XCTAssertEqual(geometry.moved(0,by:-1),0); XCTAssertEqual(geometry.moved(999,by:1),999)
        let repeated = SheetScrollGeometry(heights:[400,500],repetitions:[100_000,2])
        XCTAssertEqual(repeated.starts,[0,40_000_000]); XCTAssertEqual(repeated.totalHeight,40_001_000)
        XCTAssertEqual(repeated.location(at:39_999_999),PreviewSheetLocation(sheet:0,repetition:99_999))
        XCTAssertEqual(repeated.next(PreviewSheetLocation(sheet:0,repetition:99_999),delta:1),PreviewSheetLocation(sheet:1,repetition:0))
    }
    func testActualScrollSelectionAndVirtualization() async throws {
        let workspace = Workspace()
        workspace.project = Project(pages:(1...1200).map { SourcePage(number:$0,trimSize:Size(210,297)) },binding:.saddleStitch,
                                    sheet:SheetSpec(size:Size(420,297),margins:Insets(),gripperWidth:0,orientation:.landscape))
        workspace.project.exportMarks = .none; workspace.project.settings.cropMarkLength = 0
        for _ in 0..<200 where workspace.planning { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(workspace.plan.sheets.count,300)
        let scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:900,height:650)),document = AllSheetsDocument()
        scroll.documentView = document; document.model = workspace; document.updateGeometry(); scroll.layoutSubtreeIfNeeded()
        scroll.selectionChanged = { workspace.sheetIndex = $0; workspace.repetition = $1 }
        scroll.scrollToSheet(150)
        XCTAssertEqual(workspace.sheetIndex,150); XCTAssertEqual(scroll.reportedSelection,150)
        XCTAssertLessThan(document.subviews.count,4,"Only visible rows may allocate PDF canvases")
        scroll.allowsMagnification = true; scroll.minMagnification = 0.04
        scroll.setMagnification(0.25,centeredAt:.zero); document.updateViewportExtent()
        scroll.scrollToSheet(299)
        XCTAssertEqual(workspace.sheetIndex,299); XCTAssertLessThan(document.subviews.count,4)
    }
    func testNewSettingsSaveOpenAndLegacyDecode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let sourceURL = dir.appendingPathComponent("card.pdf")
        var media = CGRect(x:0,y:0,width:100*72/25.4,height:60*72/25.4)
        let pdf = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:sourceURL as CFURL)),mediaBox:&media,nil))
        for _ in 0..<2 { pdf.beginPDFPage(nil); pdf.setFillColor(CGColor(gray:0.4,alpha:1)); pdf.fill(media); pdf.endPDFPage() }; pdf.closePDF()
        let workspace = Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) })
        workspace.open(sourceURL)
        for _ in 0..<400 where workspace.loading || workspace.planning { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(workspace.rescalePrompt,"Measured PDF rounding must not suppress the 100×60 import question")
        workspace.rescalePrompt = nil; workspace.pendingScalePrompts = []
        workspace.project.allSheetsPreview = true
        workspace.project.rescaleJobs = [RescaleJob(pages:[1,2],settings:RescaleSettings(target:Size(90,50),mode:.fill))]
        var field = SerialField(); field.distribution = .block; field.backNumbering = .consecutive
        workspace.project.serialFields = [field]
        let url = dir.appendingPathComponent("settings.atispress"); try workspace.saveProject(as:url)
        let opened = Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) }); try await opened.loadProject(at:url)
        for _ in 0..<400 where opened.loading || opened.planning { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(opened.project,workspace.project)
        let slot = try XCTUnwrap(opened.plan.sheets.first?.front.slots.first)
        let trim = PDFPreviewDrawing.localTrim(slot) // footprint may be rotated 90°
        XCTAssertEqual(trim.width,90); XCTAssertEqual(trim.height,50)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:url)).version,17)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        json["version"] = 16
        var state = try XCTUnwrap(json["state"] as? [String:Any]),project = try XCTUnwrap(state["project"] as? [String:Any])
        project.removeValue(forKey:"rescaleJobs"); project.removeValue(forKey:"allSheetsPreview")
        var fields = try XCTUnwrap(project["serialFields"] as? [[String:Any]])
        fields[0].removeValue(forKey:"rangeDistribution"); fields[0].removeValue(forKey:"backNumber")
        project["serialFields"] = fields; state["project"] = project; json["state"] = state
        let legacy = try ProjectDocument.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(legacy.state.project.rescaleJobs); XCTAssertNil(legacy.state.project.allSheetsPreview)
        XCTAssertEqual(legacy.state.project.serialFields[0].distribution,.copy)
        XCTAssertEqual(legacy.state.project.serialFields[0].backNumbering,.same)
    }
    func testImportAndAutomaticScalePromptPreserveSettingsUntilAccepted() {
        let workspace = Workspace()
        workspace.project.pages = [SourcePage(number:1,trimSize:Size(100,60))]
        XCTAssertTrue(workspace.offerRescaling())
        XCTAssertNil(workspace.project.rescaleJobs)
        XCTAssertEqual(workspace.rescalePrompt?.settings.target,Size(90,50))
        workspace.rescalePrompt = nil
        workspace.setScale(RescaleSettings(target:Size(85,55),mode:.stretch),pages:[1],gangID:nil)
        XCTAssertTrue(workspace.offerRescaling(arrangeAfter:true))
        XCTAssertEqual(workspace.rescalePrompt?.settings.mode,.stretch)
    }
}
