import XCTest
import AppKit
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class ScaleWindowTests:XCTestCase {
    private func model(_ count:Int = 1,mode:BindingMethod = .stepAndRepeat) -> Workspace {
        let m = Workspace()
        m.project = Project(pages:(1...count).map { SourcePage(number:$0,trimSize:Size(100,70),availableBleed:0) },binding:mode,sheet:SheetSpec(size:Size(330,480)),settings:ImpositionSettings(bleed:3))
        m.project.stepAndRepeat.pageLayout = PageLayoutSettings(); m.project.stepAndRepeat.pageLayout?.mode = .simplex
        return m
    }
    func testWindowDefaultsScopeChipsAndCancelDoNotChangeProject() {
        let m = model(), baseline = m.project
        m.openScaleWindow()
        let view = ScaleWindowView(model:m,request:m.scaleWindow!)
        XCTAssertEqual(view.settings.mode,.fit); XCTAssertTrue(view.all); XCTAssertFalse(view.showsJobScope)
        XCTAssertEqual(view.settings.target,Size(100,70))
        m.scaleWindow = nil
        XCTAssertEqual(m.project,baseline)
        let many = model(3)
        XCTAssertTrue(ScaleWindowView(model:many,request:ScaleWindowRequest(row:1)).showsJobScope)
        XCTAssertEqual(ScalingPresentation.targets(booklet:false).count,9)
        XCTAssertEqual(ScalingPresentation.targets(booklet:true).map(\.0),["A5","A6"])
    }
    func testChangeLineAndWarningsUseActualEngineNotWidthOnly() {
        XCTAssertEqual(ScalingPresentation.change(source:Size(100,70),settings:RescaleSettings()),"100 × 70 mm → 90 × 50 mm (%71,4 küçülür)")
        XCTAssertEqual(ScalingPresentation.change(source:Size(100,70),settings:RescaleSettings(mode:.fill)),"100 × 70 mm → 90 × 50 mm (%90 küçülür)")
        XCTAssertTrue(ScalingPresentation.change(source:Size(210,297),settings:RescaleSettings(target:Size(148,210))).contains("%70,5"))
        XCTAssertTrue(ScalingPresentation.change(source:Size(100,70),settings:RescaleSettings(target:Size(200,140))).contains("%200 büyür"))
        let stretch = RescaleSettings(target:Size(90,50),mode:.stretch)
        XCTAssertTrue(ScalingPresentation.warnings(source:Size(100,70),settings:stretch,sourceDPI:nil).contains { $0.contains("%2") })
        XCTAssertFalse(ScalingPresentation.warnings(source:Size(100,70),settings:RescaleSettings(target:Size(101,70),mode:.stretch),sourceDPI:nil).contains { $0.contains("%2") })
        XCTAssertTrue(ScalingPresentation.warnings(source:Size(100,70),settings:RescaleSettings(target:Size(70,49)),sourceDPI:nil).contains("Yazılar %30 küçülür."))
        XCTAssertTrue(ScalingPresentation.warnings(source:Size(100,70),settings:RescaleSettings(target:Size(200,140)),sourceDPI:360).contains { $0.contains("180 dpi") })
        XCTAssertTrue(ScalingPresentation.warnings(source:Size(100,70),settings:RescaleSettings(target:Size(200,140)),sourceDPI:nil).contains { $0.contains("dpi bilgisi yok") })
    }
    func testAllAndPerJobApplyRemoveAndReturnToGeneral() {
        let m = model(3), baseline = ImpositionPlanner.plan(m.project)
        m.applyScaleWindow(RescaleSettings(),all:true,row:0)
        XCTAssertEqual(m.scalingRows.filter { $0.settings != nil }.count,3)
        m.applyScaleWindow(RescaleSettings(target:Size(85,55),mode:.stretch),all:false,row:1)
        XCTAssertEqual(m.project.rescale(for:2,jobIndex:1)?.settings.target,Size(85,55))
        XCTAssertEqual(m.project.rescale(for:1,jobIndex:0)?.settings.target,Size(90,50))
        m.applyScaleWindow(nil,all:false,row:1)
        XCTAssertNil(m.project.rescale(for:2,jobIndex:1))
        m.useGeneralScale(row:1)
        XCTAssertEqual(m.project.rescale(for:2,jobIndex:1)?.settings.target,Size(90,50))
        m.applyScaleWindow(nil,all:true,row:0)
        XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,baseline.sheets)
        XCTAssertTrue(m.scalingStatus.isEmpty)
        XCTAssertEqual(m.scalingSizeText,"Ebat: 100 × 70 mm")
    }
    func testBookletScalesEveryPageWithoutChangingCountAndGangScopeIsIndependent() {
        let book = model(12,mode:.saddleStitch)
        book.project.pages = (1...12).map { SourcePage(number:$0,trimSize:Size(210,297)) }
        let source = book.project.pages
        book.applyScaleWindow(RescaleSettings(target:Size(148,210)),all:true,row:0)
        XCTAssertEqual(book.project.pages,source)
        XCTAssertEqual(book.project.rescaledPlanningInput.pages.count,12)
        XCTAssertTrue(book.project.rescaledPlanningInput.pages.allSatisfy { $0.trimSize == Size(148,210) })
        let gang = model(2,mode:.gang)
        var settings = GangSettings()
        settings.jobs = gang.project.pages.map { GangJob(sourceID:UUID(),name:"İş",front:$0) }
        gang.project.gang = settings
        gang.applyScaleWindow(RescaleSettings(),all:false,row:1)
        XCTAssertNil(gang.scalingRows[0].settings); XCTAssertNotNil(gang.scalingRows[1].settings)
    }
    func testSuggestionRequiresClickAndNearestTargetUsesSameWindow() {
        let m = model(), baseline = m.project
        XCTAssertTrue(m.offerRescaling()); XCTAssertNil(m.scaleWindow)
        XCTAssertEqual(m.project,baseline)
        m.openScaleWindow(prompt:m.rescalePrompt)
        XCTAssertEqual(m.scaleWindow?.suggested?.target,Size(85,55))
        XCTAssertEqual(ScaleWindowView(model:m,request:m.scaleWindow!).settings.mode,.fit)
        m.scaleWindow = nil
        m.finishScaleSuggestion(m.rescalePrompt!)
        XCTAssertEqual(m.project,baseline)
    }
    func testLegacyScalingOpensWithItsExactModeAndTarget() throws {
        let m = model(2)
        m.project.rescaleJobs = [RescaleJob(pages:[1],settings:RescaleSettings(target:Size(85,55),mode:.stretch),jobIndex:0)]
        let plan = ImpositionPlanner.plan(m.project)
        m.openScaleWindow()
        let view = ScaleWindowView(model:m,request:m.scaleWindow!)
        XCTAssertEqual(view.settings.target,Size(85,55)); XCTAssertEqual(view.settings.mode,.stretch)
        XCTAssertTrue(m.scalingSizeText.contains("85 × 55 mm"))
        XCTAssertTrue(m.scalingSizeText.contains("100 × 70’den ölçeklendi"))
        m.project.migrateScaling()
        let restored = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(m.project))
        XCTAssertEqual(ImpositionPlanner.plan(restored).sheets,plan.sheets)
    }
    func testWindowAppliesExactlyTheLegacyEnginePlanAndPDFAndRemoveRestoresPixels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let input = folder.appendingPathComponent("input.pdf")
        var media = CGRect(x:0,y:0,width:100*72/25.4,height:70*72/25.4)
        let c = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:input as CFURL)),mediaBox:&media,nil))
        for i in 0..<2 {
            c.beginPDFPage(nil); c.setFillColor(CGColor(red:0.2,green:Double(i)/2,blue:0.8,alpha:1)); c.fill(media)
            c.setFillColor(CGColor(gray:0.9,alpha:1)); c.fill(CGRect(x:20,y:20,width:100,height:50)); c.endPDFPage()
        }; c.closePDF()
        let source = try await PDFSource.open(input), m = model(2)
        m.project.exportMarks = .none
        let baseline = m.project, baselinePlan = ImpositionPlanner.plan(baseline)
        func pixels(_ plan:ImpositionPlan,_ name:String) throws -> [Data] {
            let url = folder.appendingPathComponent(name+".pdf")
            _ = try PDFExporter.export(plan:plan,source:source,destination:.singlePDF(url),marks:.none)
            let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
            return try (1...doc.numberOfPages).map { i in
                let ctx = try XCTUnwrap(CGContext(data:nil,width:330,height:480,bitsPerComponent:8,bytesPerRow:1320,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(CGColor(gray:1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:330,height:480))
                let page = try XCTUnwrap(doc.page(at:i)); ctx.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:330,height:480),rotate:0,preserveAspectRatio:true)); ctx.drawPDFPage(page)
                return Data(bytes:try XCTUnwrap(ctx.data),count:ctx.bytesPerRow*ctx.height)
            }
        }
        let originalPixels = try pixels(baselinePlan,"baseline")
        m.openScaleWindow(); m.scaleWindow = nil
        XCTAssertEqual(m.project,baseline)
        XCTAssertEqual(try pixels(ImpositionPlanner.plan(m.project),"unscaled"),originalPixels)
        for mode in RescaleMode.allCases {
            let scale = RescaleSettings(target:Size(90,50),mode:mode)
            var legacy = baseline
            legacy.rescaleJobs = [RescaleJob(pages:[1,2],settings:scale)]
            let oldPlan = ImpositionPlanner.plan(legacy)
            m.applyScaleWindow(scale,all:true,row:0)
            let newPlan = ImpositionPlanner.plan(m.project)
            XCTAssertEqual(newPlan.sheets,oldPlan.sheets); XCTAssertEqual(newPlan.generatedBleed,oldPlan.generatedBleed)
            XCTAssertEqual(try pixels(newPlan,"new-"+mode.rawValue),try pixels(oldPlan,"old-"+mode.rawValue))
            m.applyScaleWindow(nil,all:true,row:0)
            XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,baselinePlan.sheets)
            XCTAssertEqual(try pixels(ImpositionPlanner.plan(m.project),"removed-"+mode.rawValue),originalPixels)
        }
    }
    func testLineLegendCoversEveryMarkAndHasCorrectSafeInset() {
        let entries = PreviewLineLegend.entries(safeArea:7.5)
        for id in ["crop","sharedCut","trim","fold","bleed","safeArea","pageLabel","sheetBoundary","margin","gripper","punch","selection","blank","error"] { XCTAssertTrue(entries.contains { $0.id == id && !$0.printed },id) }
        for id in ["cropPrint","foldPrint","bleedPrint","colorPrint","targetsPrint","infoPrint","punchPrint"] { XCTAssertTrue(entries.contains { $0.id == id && $0.printed },id) }
        XCTAssertTrue(entries.contains { $0.title == "Güvenli alan: 7,5 mm" })
        let m = model(); m.overlays = .artworkOnly; XCTAssertFalse(m.hasPreviewGuides)
        m.overlays.safeArea = true; XCTAssertTrue(m.hasPreviewGuides)
    }
    func testLightAndDarkWindowLayoutArtifacts() throws {
        let m = model(3)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/WorkflowQA")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for (name,scheme) in [("light",ColorScheme.light),("dark",.dark)] {
            let host = NSHostingView(rootView:ScaleWindowView(model:m,request:ScaleWindowRequest(row:0,suggested:RescaleSettings())).environment(\.colorScheme,scheme))
            host.frame = NSRect(x:0,y:0,width:660,height:780)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:rep)
            try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("scale-window-"+name+".png"))
        }
    }
    func testReturnToGeneralSplitsBroadExceptionWithoutChangingOtherJobs() {
        let m = model(2)
        m.updateScaling { value in
            value.enabled = true; value.defaults = RescaleSettings()
            value.overrides = [ScalingOverride(pages:[1,2],settings:RescaleSettings(target:Size(85,55),mode:.fill))]
        }
        m.useGeneralScale(row:0)
        XCTAssertEqual(m.project.rescale(for:1,jobIndex:0)?.settings.target,Size(90,50))
        XCTAssertEqual(m.project.rescale(for:2,jobIndex:1)?.settings.target,Size(85,55))
    }

}
