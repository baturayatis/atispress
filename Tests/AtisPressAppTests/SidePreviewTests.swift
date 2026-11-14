import XCTest
import AppKit
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class SidePreviewTests:XCTestCase {
    private func workspace(duplex:Bool = true,quantity:Int = 1) async throws -> Workspace {
        let model = Workspace()
        model.project = Project(pages:(1...(duplex ? 2 : 1)).map { SourcePage(number:$0,trimSize:Size(85.7,54)) },
                                sheet:SheetSpec(size:Size(120,90),margins:Insets(),gripperWidth:0),
                                settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0),
                                stepAndRepeat:StepAndRepeatSettings(columns:1,rows:1,quantity:quantity))
        model.project.exportMarks = .none
        for _ in 0..<300 where model.planning { try await Task.sleep(for:.milliseconds(10)) }
        return model
    }
    func testSingleDuplexSheetDefaultsToTwoBlocksAndFrontOnlyToOne() async throws {
        let duplex = try await workspace()
        XCTAssertEqual(duplex.plan.sheets.count,1); XCTAssertTrue(duplex.showsAllSides)
        XCTAssertEqual(duplex.previewGeometry.blockCount,2)
        let first = PreviewSheetLocation(sheet:0,repetition:0)
        XCTAssertEqual(duplex.previewGeometry.next(first,delta:1).side,.back)
        let front = try await workspace(duplex:false)
        XCTAssertEqual(front.previewGeometry.blockCount,1); XCTAssertFalse(front.showsAllSides)
        front.showsAllSides = true
        let document = AllSheetsDocument(),scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:500,height:400))
        scroll.documentView = document; document.model = front; document.updateGeometry(); scroll.layoutSubtreeIfNeeded(); document.refreshVisible()
        XCTAssertTrue(document.subviews.flatMap(\.subviews).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("Arka yüz yok") })
    }
    func testSideOrderAndBoundariesStayCompactFor100000RepeatedSheets() {
        let geometry = SideScrollGeometry(heights:[400,500],repetitions:[100_000,1],backs:[true,false])
        XCTAssertEqual(geometry.blockCount,200_001); XCTAssertEqual(geometry.starts,[0,80_000_000])
        let front = PreviewSheetLocation(sheet:0,repetition:0),back = PreviewSheetLocation(sheet:0,repetition:0,side:.back)
        XCTAssertEqual(geometry.next(front,delta:1),back)
        XCTAssertEqual(geometry.next(back,delta:1),PreviewSheetLocation(sheet:0,repetition:1))
        XCTAssertEqual(geometry.next(front,delta:-1),front)
        XCTAssertEqual(geometry.location(at:400),back)
        XCTAssertEqual(geometry.location(at:80_000_000),PreviewSheetLocation(sheet:1,repetition:0))
        XCTAssertEqual(geometry.next(PreviewSheetLocation(sheet:1,repetition:0),delta:-1),PreviewSheetLocation(sheet:0,repetition:99_999,side:.back))
    }
    func testScrollSynchronizesFaceAndSheetAndListSelectionReturnsToFront() async throws {
        let model = try await workspace(quantity:4)
        let scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:500,height:400)),document = AllSheetsDocument()
        scroll.documentView = document; document.model = model; document.updateGeometry(); scroll.layoutSubtreeIfNeeded()
        scroll.locationChanged = model.selectPreviewLocation
        scroll.scrollToSheet(0,repetition:1,side:.back)
        XCTAssertEqual(model.repetition,1); XCTAssertEqual(model.side,.back)
        let canvases = document.subviews.flatMap(\.subviews).compactMap { $0 as? SheetCanvasView }
        let back = try XCTUnwrap(canvases.first { $0.sideKind == .back })
        XCTAssertEqual(back.side,model.plan.sheets[0].back,"Use the printed back transform unchanged")
        model.selectPreviewSheet(0)
        XCTAssertEqual(model.repetition,0); XCTAssertEqual(model.side,.front)
        scroll.scrollToSheet(model.sheetIndex,repetition:model.repetition,side:model.side)
        XCTAssertEqual(scroll.reportedSide,.front)
        let next = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:125)!
        scroll.keyDown(with:next)
        XCTAssertEqual(model.side,.back)
        XCTAssertLessThan(document.subviews.count,4)
        model.showsAllSides = false; model.movePreviewSheet(1)
        XCTAssertEqual(model.previewSheetPosition,"Tabaka 2 / 4"); XCTAssertEqual(model.side,.back)
    }
    func testCardOrientationAndToolbarAndMenuReachability() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func code(_ file:String) throws -> String { try String(contentsOf:root.appendingPathComponent("Sources/AtisPressApp/\(file).swift"),encoding:.utf8) }
        let inspector = try code("InspectorView"),toolbar = try code("WorkspaceView"),menu = try code("AtisPressApp")
        let card = inspector.components(separatedBy:"private var workflowPaper")[1].components(separatedBy:"private var workflowCut")[0]
        XCTAssertTrue(card.contains("Picker(\"Yön\"")); XCTAssertTrue(card.contains("AutomaticPill(model:model,field:.orientation)"))
        XCTAssertEqual(inspector.components(separatedBy:"Picker(\"Yön\"").count-1,1)
        XCTAssertFalse(inspector.contains("autoLabel(\"Yön\""))
        XCTAssertTrue(toolbar.contains("PreviewScopePicker(model:model)"))
        for key in ["Tüm yüzler","Tek yüz"] { XCTAssertTrue(inspector.contains(key)); XCTAssertTrue(menu.contains(key)) }
        // All preview controls must be reachable in both the toolbar and native menu.
        for key in ["Sığdır","Yakınlaştır","Uzaklaştır","Önceki tabaka","Sonraki tabaka"] {
            XCTAssertTrue(toolbar.contains(key),key); XCTAssertTrue(menu.contains(key),key)
        }
        XCTAssertTrue(toolbar.contains("Picker(\"Yüz\"")); XCTAssertTrue(menu.contains("workspace.side = .front")); XCTAssertTrue(menu.contains("workspace.side = .back"))
    }
    func testFaceSegmentAndSheetListRevealCorrectBlockAcrossSheets() async throws {
        let model = Workspace()
        model.project = Project(pages:(1...8).map { SourcePage(number:$0,trimSize:Size(100,140)) },binding:.saddleStitch,
                                sheet:SheetSpec(size:Size(300,200),margins:Insets(),gripperWidth:0,orientation:.landscape))
        for _ in 0..<300 where model.planning { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.displaySheets.count,2)
        let scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:500,height:400)),document = AllSheetsDocument()
        scroll.documentView = document; document.model = model; document.updateGeometry(); scroll.layoutSubtreeIfNeeded()
        scroll.locationChanged = model.selectPreviewLocation
        model.side = .back // The same binding as the Ön / Arka segment.
        scroll.revealSelection(PreviewSheetLocation(sheet:model.sheetIndex,repetition:model.repetition,side:model.side))
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1).side,.back)
        scroll.scrollToSheet(1,side:.back)
        XCTAssertEqual(model.sheetIndex,1); XCTAssertEqual(model.side,.back)
        model.selectPreviewSheet(0) // The left sheet-list selection binding.
        scroll.revealSelection(PreviewSheetLocation(sheet:model.sheetIndex,repetition:model.repetition,side:model.side))
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1),PreviewSheetLocation(sheet:0,repetition:0))
        model.revealWorkflowIssue(ValidationIssue(.warning,.missingBleed,"Eksik taşma",slot:SlotReference(sheet:1,side:.back,slot:0)))
        scroll.revealSelection(PreviewSheetLocation(sheet:model.sheetIndex,repetition:model.repetition,side:model.side))
        XCTAssertEqual(model.sheetIndex,1); XCTAssertEqual(model.side,.back)
        XCTAssertEqual(model.ui.focusedArea,.bleed)
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1).side,.back)
    }
    func testPreviewModesAndNavigationKeepSavedPlanAndPDFPixelsIdentical() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("existing.pdf")
        var media = CGRect(x:0,y:0,width:85.7*72/25.4,height:54*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:url as CFURL)),mediaBox:&media,nil))
        for gray in [CGFloat(0.2),0.7] {
            context.beginPDFPage(nil); context.setFillColor(CGColor(gray:gray,alpha:1)); context.fill(media)
            context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:5,y:10,width:25,height:35)); context.endPDFPage()
        }
        context.closePDF()
        func workspace() -> Workspace { Workspace(bookmarkCreator:{ try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil) }) }
        func settle(_ model:Workspace) async throws {
            for _ in 0..<500 where model.loading || model.planning || model.autoArranging { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertFalse(model.loading || model.planning || model.autoArranging)
        }
        let model = workspace(); model.open(url,confirmChanges:false); try await settle(model)
        model.project = Project(pages:try XCTUnwrap(model.source).pages.map(\.sourcePage),
                                sheet:SheetSpec(size:Size(220,160),margins:Insets(),gripperWidth:0,orientation:.landscape),
                                settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0),
                                stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,allowRotation:false,quantity:5))
        model.project.exportMarks = .none; try await settle(model)
        let saved = directory.appendingPathComponent("existing.atispress"); try model.saveProject(as:saved)
        let existing = workspace(); try await existing.loadProject(at:saved); try await settle(existing)
        let snapshot = existing.plan
        func pixels(_ name:String) throws -> [Data] {
            let out = directory.appendingPathComponent(name+".pdf")
            _ = try PDFExporter.export(plan:existing.plan,source:XCTUnwrap(existing.source),destination:.singlePDF(out),marks:existing.project.exportMarks)
            let pdf = try XCTUnwrap(CGPDFDocument(out as CFURL))
            return try (1...pdf.numberOfPages).map { number in
                let bitmap = try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                let page = try XCTUnwrap(pdf.page(at:number))
                bitmap.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:320,height:240),rotate:0,preserveAspectRatio:true)); bitmap.drawPDFPage(page)
                return Data(bytes:try XCTUnwrap(bitmap.data),count:bitmap.bytesPerRow*bitmap.height)
            }
        }
        let before = try pixels("before")
        existing.showsAllSides = true; existing.selectPreviewLocation(PreviewSheetLocation(sheet:0,repetition:1,side:.back))
        existing.zoomFactor = 1.25; existing.zoomAction += 1
        existing.showsAllSides = false; existing.movePreviewSheet(-1)
        XCTAssertEqual(existing.plan.sheets,snapshot.sheets); XCTAssertEqual(existing.plan.issues,snapshot.issues)
        XCTAssertEqual(try pixels("after"),before)
        try existing.saveProject(as:saved)
        let reopened = workspace(); try await reopened.loadProject(at:saved); try await settle(reopened)
        XCTAssertFalse(reopened.showsAllSides); XCTAssertEqual(reopened.project,existing.project)
        XCTAssertEqual(reopened.plan.sheets,snapshot.sheets)
        let prices = PricingStore(url:directory.appendingPathComponent("prices.json"))
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/WorkflowQA")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for scheme in [ColorScheme.light,.dark] {
            existing.showsAllSides = true
            let host = NSHostingView(rootView:WorkspaceView(model:existing,prices:prices).environment(\.colorScheme,scheme))
            host.appearance = NSAppearance(named:scheme == .light ? .aqua : .darkAqua)
            host.frame = CGRect(origin:.zero,size:DesignSystem.minimumWindow); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for:.milliseconds(30)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent(scheme == .light ? "sides-light.png" : "sides-dark.png"))
        }
    }

    func testThousandPlusSidesOnlyAllocateVisibleRows() async throws {
        let model = Workspace()
        model.project = Project(pages:(1...2400).map { SourcePage(number:$0,trimSize:Size(100,140)) },binding:.saddleStitch,
                                sheet:SheetSpec(size:Size(300,200),margins:Insets(),gripperWidth:0,orientation:.landscape))
        for _ in 0..<400 where model.planning { try await Task.sleep(for:.milliseconds(10)) }
        let scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:500,height:400)),document = AllSheetsDocument()
        scroll.documentView = document; document.model = model; document.updateGeometry(); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(document.geometry.blockCount,1200)
        scroll.scrollToSheet(599,side:.back)
        XCTAssertEqual(scroll.reportedSelection,599); XCTAssertEqual(scroll.reportedSide,.back)
        XCTAssertLessThan(document.subviews.count,4)
    }

    func testDeferredScrollSyncCannotOverwriteLaterFaceSelection() async throws {
        let model = try await workspace(quantity:3),scroll = AllSheetsScrollView()
        scroll.lastModelLocation = PreviewSheetLocation(sheet:0,repetition:0)
        scroll.queueSelection(PreviewSheetLocation(sheet:0,repetition:1),model:model)
        model.side = .back
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(model.side,.back); XCTAssertEqual(model.repetition,0)
        scroll.lastModelLocation = PreviewSheetLocation(sheet:0,repetition:0,side:.back)
        scroll.queueSelection(PreviewSheetLocation(sheet:0,repetition:1),model:model)
        scroll.queueSelection(PreviewSheetLocation(sheet:0,repetition:2,side:.back),model:model)
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(model.side,.back); XCTAssertEqual(model.repetition,2)
    }

    func testHostedPreviewFaceSegmentBindingScrollsAndStaysSynchronized() async throws {
        let model = try await workspace(quantity:3)
        model.side = .back
        model.zoomFactor = 1.25; model.zoomAction += 1
        let host = NSHostingView(rootView:AllSheetsPreview(model:model))
        host.frame = NSRect(x:0,y:0,width:500,height:400); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(30)); host.layoutSubtreeIfNeeded()
        func find(_ view:NSView) -> AllSheetsScrollView? {
            if let scroll = view as? AllSheetsScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        let scroll = try XCTUnwrap(find(host)),document = try XCTUnwrap(scroll.documentView as? AllSheetsDocument)
        XCTAssertEqual(model.side,.back)
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1).side,.back)
        model.side = .front
        try await Task.sleep(for:.milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1).side,.front)
        model.side = .back
        try await Task.sleep(for:.milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1).side,.back)
        scroll.scrollToSheet(0,repetition:2,side:.front)
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(model.side,.front); XCTAssertEqual(model.repetition,2)
    }

}
