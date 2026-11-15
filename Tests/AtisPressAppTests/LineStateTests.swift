import XCTest
import SwiftUI
import AppKit
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class LineStateTests:XCTestCase {
    func testTwelveA4SaddleCropOffRestoresExactCanvas() throws {
        let m = Workspace()
        m.project = Project(pages:(1...12).map { SourcePage(number:$0,trimSize:Size(210,297),availableBleed:3) },binding:.saddleStitch,sheet:SheetSpec(size:Size(450,330)),settings:ImpositionSettings(bleed:3))
        m.project.exportMarks.crop = false
        let before = ImpositionPlanner.plan(m.project)
        XCTAssertEqual(before.sheets.count,3)
        m.overlays = .artworkOnly
        let canvas = SheetCanvasView(frame:NSRect(x:0,y:0,width:600,height:800))
        func pixels(_ focus:WorkflowFocus?) throws -> Data {
            let sheet = ImpositionPlanner.plan(m.project).sheets[0]
            canvas.focusArea = focus
            canvas.configure(sheet:sheet,side:sheet.front,source:nil,overlays:m.overlays,highlighted:[],controlMarks:m.project.exportMarks)
            let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
            canvas.cacheDisplay(in:canvas.bounds,to:rep)
            return Data(bytes:try XCTUnwrap(rep.bitmapData),count:rep.bytesPerRow*rep.pixelsHigh)
        }
        let baseline = try pixels(nil)
        let binding = m.autoBinding(Binding(get:{m.project.exportMarks.crop},set:{m.project.exportMarks.crop = $0}),.exportCrop)
        binding.wrappedValue = true
        m.ui.focusedArea = WorkflowPresentation.focus(.exportCrop) // Same focus/tap route as card 3.
        _ = try pixels(m.ui.focusedArea)
        binding.wrappedValue = false
        XCTAssertEqual(ImpositionPlanner.plan(m.project).sheets,before.sheets)
        XCTAssertEqual(try pixels(m.ui.focusedArea),baseline,"A printed-mark toggle must not leave an inset focus rectangle")
    }
    func testAllSidesRefreshesPrintedInfoAndGuideStateWithoutRebuildingPlan() async throws {
        let m = Workspace()
        m.project.pages = [SourcePage(number:1,trimSize:Size(85,55),availableBleed:3)]
        for _ in 0..<200 where m.planning { try await Task.sleep(for:.milliseconds(10)) }
        let doc = AllSheetsDocument(), scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:600,height:500))
        scroll.documentView = doc; doc.model = m; doc.updateGeometry(); scroll.layoutSubtreeIfNeeded(); doc.refreshVisible()
        m.project.exportMarks.sheetInfo = true
        doc.updateGeometry(); doc.refreshVisible()
        m.infoJobName = "Önce"
        doc.updateGeometry(); doc.refreshVisible()
        let canvas = try XCTUnwrap(doc.subviews.flatMap(\.subviews).compactMap { $0 as? SheetCanvasView }.first)
        XCTAssertTrue(canvas.printedInfo.contains("Önce"))
        let sheets = m.plan.sheets
        m.infoJobName = "Sonra"
        doc.updateGeometry(); doc.refreshVisible()
        XCTAssertTrue(canvas.printedInfo.contains("Sonra"))
        XCTAssertFalse(canvas.printedInfo.contains("Önce"))
        XCTAssertEqual(m.plan.sheets,sheets)
        m.overlays.safeArea = true; doc.updateGeometry(); doc.refreshVisible()
        XCTAssertTrue(canvas.overlays.safeArea)
        m.overlays.safeArea = false; doc.updateGeometry(); doc.refreshVisible()
        XCTAssertFalse(canvas.overlays.safeArea)
    }

}
