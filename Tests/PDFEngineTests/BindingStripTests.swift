import XCTest
import PDFEngine
import ImpositionCore

final class BindingStripTests: XCTestCase {
    func testPreserveChecksBothLocalStripEdgesAndDoesNotFlagWhiteOrOffStripArtwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("strips.pdf"),unit = PDFPreviewDrawing.pointsPerMM
        var media = CGRect(x:0,y:0,width:40*unit,height:60*unit)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        for number in 1...4 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(media)
            context.setFillColor(CGColor(gray:0,alpha:1))
            if number == 1 { context.fill(CGRect(x:0,y:0,width:3*unit,height:60*unit)) }
            if number == 2 { context.fill(CGRect(x:37*unit,y:0,width:3*unit,height:60*unit)) }
            if number == 4 { context.fill(CGRect(x:15*unit,y:20*unit,width:10*unit,height:10*unit)) }
            context.endPDFPage()
        }
        context.closePDF()
        let source = try await PDFSource.open(url)
        var p = Project(pages:source.pages.map(\.sourcePage),binding:.spiral,sheet:SheetSpec(size:Size(200,200)),
            settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0,safeAreaInset:0),stepAndRepeat:StepAndRepeatSettings(columns:1,rows:1,allowRotation:false))
        p.leafSettings.allowance = 5
        let plan = ImpositionPlanner.plan(p)
        let warnings = PDFBindingStripInspector.warnings(plan:plan,url:source.url,cache:source.bindingStripCache)
        XCTAssertEqual(warnings.count,1)
        XCTAssertEqual(warnings.first?.affectedPages,[1,2])
        XCTAssertTrue(warnings.first?.message.contains("beyaz olmayan") == true)
        XCTAssertEqual(warnings,PDFBindingStripInspector.warnings(plan:plan,url:source.url,cache:source.bindingStripCache))
        let unavailable = PDFBindingStripInspector.warnings(plan:plan,url:folder.appendingPathComponent("missing.pdf"))
        XCTAssertTrue(unavailable.first?.message.contains("kontrol edilemedi") == true)
        for behavior in [BindingAllowanceBehavior.shrink,.shift] {
            p.leafSettings.behavior = behavior
            XCTAssertTrue(PDFBindingStripInspector.warnings(plan:ImpositionPlanner.plan(p),url:source.url).isEmpty)
        }
    }
}
