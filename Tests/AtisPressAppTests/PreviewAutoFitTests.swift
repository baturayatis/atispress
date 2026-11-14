import XCTest
import AppKit
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class PreviewAutoFitTests:XCTestCase {
    func testFitScalesAndCapsAcrossPaperAndViewportSizes() {
        for (paper,viewport) in [(Size(90,50),CGSize(width:1200,height:900)),(Size(210,297),CGSize(width:1100,height:900)),(Size(480,330),CGSize(width:500,height:400)),(Size(700,1000),CGSize(width:350,height:500))] {
            let document = CGSize(width:paper.width*72/25.4+64,height:paper.height*72/25.4+110)
            let width = PreviewFit.scale(document:document,paper:paper,viewport:viewport,mode:.width)
            let whole = PreviewFit.scale(document:document,paper:paper,viewport:viewport,mode:.whole)
            XCTAssertLessThanOrEqual(document.width*width,viewport.width-32+0.001)
            XCTAssertLessThanOrEqual(document.width*whole,viewport.width-32+0.001)
            XCTAssertLessThanOrEqual(document.height*whole,viewport.height-32+0.001)
            XCTAssertLessThanOrEqual(whole,width)
        }
        XCTAssertEqual(PreviewFit.scale(document:CGSize(width:320,height:220),paper:Size(90,50),viewport:CGSize(width:3000,height:3000),mode:.width),1)
        XCTAssertEqual(PreviewFit.scale(document:CGSize(width:660,height:900),paper:Size(210,297),viewport:CGSize(width:5000,height:5000),mode:.whole),3)
        XCTAssertGreaterThan(PreviewFit.scale(document:CGSize(width:660,height:900),paper:Size(210,297),viewport:CGSize(width:1500,height:1500),mode:.whole),1)
        XCTAssertEqual(PreviewFit.scale(document:CGSize(width:1000,height:2000),paper:Size(330,480),viewport:CGSize(width:532,height:432),mode:.width),0.5,accuracy:0.0001)
        XCTAssertEqual(PreviewFit.scale(document:CGSize(width:1000,height:2000),paper:Size(330,480),viewport:CGSize(width:532,height:432),mode:.whole),0.2,accuracy:0.0001)
    }
    private func canvas(_ size:Size) -> SheetCanvasView {
        let canvas = SheetCanvasView()
        canvas.configure(sheet:Sheet(size:size,front:Side(),back:Side()),side:Side(),source:nil,overlays:PreviewOverlays(),highlighted:[])
        return canvas
    }
    private func scroll(_ size:Size) -> PreviewScrollView {
        let scroll = PreviewScrollView(frame:NSRect(x:0,y:0,width:700,height:500))
        scroll.allowsMagnification = true; scroll.minMagnification = 0.001; scroll.maxMagnification = 12
        scroll.documentView = canvas(size); scroll.layoutSubtreeIfNeeded()
        return scroll
    }
    func testWholeFitRetriggersOnResizeSheetAndOrientationChanges() {
        let scroll = scroll(Size(480,330))
        let initial = scroll.magnification
        scroll.setFrameSize(NSSize(width:450,height:350)); scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(scroll.magnification,initial)
        XCTAssertLessThanOrEqual(scroll.fitDocumentSize.width*scroll.magnification,scroll.contentSize.width)
        XCTAssertLessThanOrEqual(scroll.fitDocumentSize.height*scroll.magnification,scroll.contentSize.height)
        let landscape = scroll.magnification
        let view = scroll.documentView as! SheetCanvasView
        view.configure(sheet:Sheet(size:Size(330,480),front:Side(),back:Side()),side:Side(),source:nil,overlays:PreviewOverlays(),highlighted:[])
        scroll.requestFit(); scroll.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(scroll.magnification,landscape)
        view.configure(sheet:Sheet(size:Size(90,50),front:Side(),back:Side()),side:Side(),source:nil,overlays:PreviewOverlays(),highlighted:[])
        scroll.requestFit(); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification,1)
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }
    func testManualZoomSurvivesResizeAndGeometryUntilFitResumes() async throws {
        let model = Workspace(),scroll = scroll(Size(480,330))
        scroll.synchronizeZoom(model); scroll.layoutSubtreeIfNeeded()
        model.zoomFactor = 1.25; model.zoomAction += 1
        scroll.synchronizeZoom(model)
        let manual = scroll.magnification
        XCTAssertFalse(model.zoomAutomatic); XCTAssertFalse(scroll.autoFitEnabled)
        scroll.setFrameSize(NSSize(width:400,height:300)); scroll.layoutSubtreeIfNeeded()
        let view = scroll.documentView as! SheetCanvasView
        view.configure(sheet:Sheet(size:Size(700,1000),front:Side(),back:Side()),side:Side(),source:nil,overlays:PreviewOverlays(),highlighted:[])
        scroll.requestFit(); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification,manual)
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(model.zoomStateLabel,"%\(Int((manual*100).rounded()))")
        model.zoomFactor = 0; model.zoomAction += 1
        scroll.synchronizeZoom(model); scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.zoomAutomatic); XCTAssertTrue(scroll.autoFitEnabled)
        XCTAssertEqual(model.zoomStateLabel,"Otomatik sığdır")
        XCTAssertLessThan(scroll.magnification,manual)
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }
    private func workspace() async throws -> Workspace {
        let model = Workspace()
        model.project = Project(pages:[SourcePage(number:1,trimSize:Size(85.7,54)),SourcePage(number:2,trimSize:Size(85.7,54))],sheet:SheetSpec(size:Size(480,330),margins:Insets(),gripperWidth:0,orientation:.landscape),settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:1,rows:1,quantity:4))
        for _ in 0..<300 where model.planning { try await Task.sleep(for:.milliseconds(10)) }
        return model
    }
    func testWidthFitPreservesSelectedBackAndOffsetAcrossResize() async throws {
        let model = try await workspace()
        let scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:700,height:500)),document = AllSheetsDocument()
        scroll.allowsMagnification = true; scroll.minMagnification = 0.001; scroll.maxMagnification = 12
        scroll.documentView = document; document.model = model; document.updateGeometry(); scroll.layoutSubtreeIfNeeded()
        scroll.scrollToSheet(0,repetition:2,side:.back)
        let location = PreviewSheetLocation(sheet:0,repetition:2,side:.back)
        let original = scroll.magnification
        scroll.setFrameSize(NSSize(width:450,height:650)); scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(scroll.magnification,original)
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1),location)
        XCTAssertEqual(scroll.documentVisibleRect.minY,document.geometry.origin(location),accuracy:1)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(document.frame.width*scroll.magnification,scroll.contentSize.width)
        scroll.manualZoom(by:1.35); let manual = scroll.magnification
        scroll.setFrameSize(NSSize(width:900,height:500)); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification,manual)
        scroll.autoFitEnabled = true; scroll.requestFit(); scroll.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(scroll.magnification,manual)
        XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1),location)
    }
    func testViewSwitchRespectsManualScaleAndFitRestartsBothViews() async throws {
        let model = try await workspace()
        let host = NSHostingView(rootView:WorkspaceView(model:model,prices:PricingStore(url:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))))
        host.frame = CGRect(origin:.zero,size:DesignSystem.minimumWindow); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(30))
        func find(_ view:NSView) -> AutoFitScrollView? {
            if let scroll = view as? AutoFitScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        XCTAssertTrue(model.zoomAutomatic)
        var preview = try XCTUnwrap(find(host))
        preview.manualZoom(by:1.35)
        try await Task.sleep(for:.milliseconds(30))
        let manual = preview.magnification
        model.showsAllSides = false
        try await Task.sleep(for:.milliseconds(30)); host.layoutSubtreeIfNeeded()
        preview = try XCTUnwrap(find(host))
        XCTAssertTrue(preview is PreviewScrollView); XCTAssertFalse(preview.autoFitEnabled)
        XCTAssertEqual(preview.magnification,manual,accuracy:0.001)
        model.zoomFactor = 0; model.zoomAction += 1
        try await Task.sleep(for:.milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(preview.autoFitEnabled); XCTAssertFalse(preview.hasHorizontalScroller)
        model.showsAllSides = true
        try await Task.sleep(for:.milliseconds(30)); host.layoutSubtreeIfNeeded()
        preview = try XCTUnwrap(find(host))
        XCTAssertTrue(preview is AllSheetsScrollView); XCTAssertTrue(preview.autoFitEnabled)
        XCTAssertFalse(preview.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(preview.fitDocumentSize.width*preview.magnification,preview.contentSize.width)
        let artifacts = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/WorkflowQA")
        try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            host.appearance = NSAppearance(named:appearance); host.needsLayout = true; host.layoutSubtreeIfNeeded()
            try await Task.sleep(for:.milliseconds(30))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:artifacts.appendingPathComponent("auto-fit-"+name+".png"))
        }
    }
    func testHostedResizeKeepsBackAndCommandScrollPausesFit() async throws {
        let model = try await workspace()
        let host = NSHostingView(rootView:AllSheetsPreview(model:model))
        host.frame = NSRect(x:0,y:0,width:700,height:500); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(30))
        func find(_ view:NSView) -> AllSheetsScrollView? {
            if let scroll = view as? AllSheetsScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        let scroll = try XCTUnwrap(find(host)),document = try XCTUnwrap(scroll.documentView as? AllSheetsDocument)
        let location = PreviewSheetLocation(sheet:0,repetition:2,side:.back)
        model.selectPreviewLocation(location)
        try await Task.sleep(for:.milliseconds(30))
        for size in [CGSize(width:400,height:700),CGSize(width:900,height:400),CGSize(width:500,height:500)] {
            host.setFrameSize(size); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for:.milliseconds(30))
            XCTAssertEqual(document.geometry.location(at:scroll.documentVisibleRect.minY+1),location)
            XCTAssertEqual(model.side,.back); XCTAssertEqual(model.repetition,2)
            XCTAssertLessThanOrEqual(document.frame.width*scroll.magnification,scroll.contentSize.width)
            XCTAssertFalse(scroll.hasHorizontalScroller)
            XCTAssertGreaterThanOrEqual(document.headerHeight*scroll.magnification,31.9)
            let labels = document.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
            XCTAssertFalse(labels.isEmpty)
            for label in labels { XCTAssertGreaterThanOrEqual((label.font?.pointSize ?? 0)*scroll.magnification,11.9) }
        }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:20,wheel2:0,wheel3:0))
        cg.flags = .maskCommand
        scroll.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:cg)))
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertFalse(model.zoomAutomatic)
        let manual = scroll.magnification
        host.setFrameSize(CGSize(width:800,height:650)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification,manual)
    }
    func testFitAndResizeDoNotChangeProjectPlanOrPDFSnapshot() async throws {
        let model = try await workspace(),directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let input = directory.appendingPathComponent("input.pdf")
        var media = CGRect(x:0,y:0,width:85.7*72/25.4,height:54*72/25.4)
        let context = try XCTUnwrap(CGContext(consumer:XCTUnwrap(CGDataConsumer(url:input as CFURL)),mediaBox:&media,nil))
        for gray in [CGFloat(0.2),0.7] {
            context.beginPDFPage(nil); context.setFillColor(CGColor(gray:gray,alpha:1)); context.fill(media)
            context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:3,y:7,width:23,height:37)); context.endPDFPage()
        }; context.closePDF()
        let source = try await PDFSource.open(input)
        let project = model.project,plan = model.plan
        func pixels(_ name:String) throws -> [Data] {
            let out = directory.appendingPathComponent(name+".pdf")
            _ = try PDFExporter.export(plan:model.plan,source:source,destination:.singlePDF(out),marks:model.project.exportMarks)
            let pdf = try XCTUnwrap(CGPDFDocument(out as CFURL))
            return try (1...pdf.numberOfPages).map { number in
                let bitmap = try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                let page = try XCTUnwrap(pdf.page(at:number))
                bitmap.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(x:0,y:0,width:320,height:240),rotate:0,preserveAspectRatio:true)); bitmap.drawPDFPage(page)
                return Data(bytes:try XCTUnwrap(bitmap.data),count:bitmap.bytesPerRow*bitmap.height)
            }
        }
        let before = try pixels("before")
        let scroll = AllSheetsScrollView(frame:NSRect(x:0,y:0,width:700,height:500)),document = AllSheetsDocument()
        scroll.allowsMagnification = true; scroll.minMagnification = 0.001; scroll.maxMagnification = 12
        scroll.documentView = document; document.model = model; document.updateGeometry()
        scroll.synchronizeZoom(model); scroll.layoutSubtreeIfNeeded()
        scroll.setFrameSize(CGSize(width:450,height:700)); scroll.layoutSubtreeIfNeeded()
        scroll.manualZoom(by:1.35)
        model.zoomFactor = 0; model.zoomAction += 1
        scroll.synchronizeZoom(model); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.project,project); XCTAssertEqual(model.plan.sheets,plan.sheets); XCTAssertEqual(model.plan.issues,plan.issues)
        XCTAssertEqual(try pixels("after"),before)
        model.zoomFactor = 1.25; model.zoomAction += 1
        XCTAssertFalse(model.zoomAutomatic)
        model.open(input,confirmChanges:false)
        for _ in 0..<400 where model.loading || model.planning || model.autoArranging { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(model.source); XCTAssertTrue(model.zoomAutomatic,"A new PDF resets the transient preview state")
    }

    func testNewProjectStartsAutomaticAfterManualZoom() {
        let model = Workspace()
        model.zoomFactor = 1.35; model.zoomAction += 1; model.zoomScale = 1.35
        XCTAssertFalse(model.zoomAutomatic); XCTAssertEqual(model.zoomStateLabel,"%135")
        model.createNewProject()
        XCTAssertTrue(model.zoomAutomatic); XCTAssertEqual(model.zoomStateLabel,"Otomatik sığdır")
    }

}
