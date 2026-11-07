import XCTest
import AppKit
import UniformTypeIdentifiers
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class WorkspaceTests: XCTestCase {
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<200 {
            if !model.planning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Planner did not settle")
    }
    func testDebouncePublishesOnlyLatestProjectAndClearsInvalidPlan() async throws {
        let model = Workspace()
        model.setMode(.saddleStitch)
        for count in 1...40 {
            model.project.pages = (1...count).map { SourcePage(number: $0,trimSize: Size(100,140),availableBleed: 3) }
        }
        XCTAssertTrue(model.planning)
        try await settle(model)
        let pages = model.plan.sheets.flatMap { $0.front.slots+$0.back.slots }.compactMap(\.sourcePageNumber)
        XCTAssertEqual(pages.sorted(),Array(1...40))
        model.project.pages = []
        try await settle(model)
        XCTAssertTrue(model.plan.sheets.isEmpty)
        XCTAssertFalse(model.plan.canExport)
    }
    func testSettingsReplanAndValidationNavigatesToSlot() async throws {
        let model = Workspace()
        model.setMode(.saddleStitch)
        model.project.pages = (1...10).map { SourcePage(number: $0,trimSize: Size(100,140),availableBleed: 0) }
        try await settle(model)
        let oldSlots = model.plan.sheets[0].front.slots
        model.project.sheet.margins.left = 31
        try await settle(model)
        XCTAssertNotEqual(model.plan.sheets[0].front.slots,oldSlots)
        let issue = try XCTUnwrap(model.plan.issues.first { $0.slot?.side == .back })
        model.reveal(issue)
        XCTAssertEqual(model.side,.back)
        XCTAssertFalse(model.highlightedSlots.isEmpty)
        model.project.binding = .perfectBound
        model.project.settings.signatureSize = .eight
        try await settle(model)
        XCTAssertEqual(model.plan.signaturePageCount,8)
        XCTAssertEqual(model.plan.addedBlankPages,6)
    }
    func testNewWorkspaceDefaultsToRepeatAndProjectKeepsModeAndExportChoices() {
        XCTAssertEqual(Project(pages: [],sheet: SheetSpec(preset: .a3)).binding,.stepAndRepeat)
        let model = Workspace()
        XCTAssertEqual(model.project.binding,.stepAndRepeat)
        XCTAssertEqual(model.project.sheet.gutter,0)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.sra3.size)
        XCTAssertEqual(model.sheetPreset,Workspace.automaticSheetTitle)
        XCTAssertTrue(model.project.exportMarks.crop)
        XCTAssertEqual(model.project.exportMarks.lineWidth,0.25)
        model.project.exportMarks.sheetInfo = true
        model.overlays = .artworkOnly
        XCTAssertTrue(model.project.exportMarks.crop)
        XCTAssertTrue(model.project.exportMarks.sheetInfo)
        model.setMode(.perfectBound)
        let saved = model.project
        let restored = Workspace()
        restored.project = saved
        XCTAssertEqual(restored.project.binding,.perfectBound)
        XCTAssertEqual(restored.project.exportMarks,saved.exportMarks)
        XCTAssertEqual(Workspace().project.binding,.stepAndRepeat)
    }

    func testExportSettingsDoNotReplanOrChangePreview() async throws {
        let model = Workspace()
        model.project.pages = [SourcePage(number: 1,trimSize: Size(85,55))]
        try await settle(model)
        let overlays = model.overlays
        let slots = model.currentSide?.slots
        model.project.exportMarks.crop = false
        model.project.exportMarks.color = .registration
        XCTAssertFalse(model.planning)
        XCTAssertEqual(model.overlays,overlays)
        XCTAssertEqual(model.currentSide?.slots,slots)
    }

    func testSerialEditingAndDuplicationUpdatePlanWithoutDebounce() async throws {
        let model = Workspace()
        model.project.pages = [1,2].map { SourcePage(number: $0,trimSize: Size(85,55)) }
        try await settle(model)
        let slots = model.currentSide?.slots
        let id = model.addSerialField()
        XCTAssertFalse(model.planning)
        XCTAssertEqual(model.currentSheet?.serialPlan?.fields.first?.id,id)
        model.moveSerialField(id,to: Point(12.4,18.6))
        XCTAssertEqual(model.currentSheet?.serialPlan?.fields.first?.position,Point(12,19))
        XCTAssertEqual(model.currentSide?.slots,slots)
        model.duplicateSerialField(id)
        XCTAssertEqual(model.project.serialFields.count,2)
        XCTAssertNotEqual(model.project.serialFields[0].id,model.project.serialFields[1].id)
        XCTAssertEqual(model.project.serialFields[1].position,Point(15,22))
        XCTAssertEqual(model.project.serialFields[1].font,model.project.serialFields[0].font)
        XCTAssertEqual(model.currentSheet?.serialPlan?.fields.count,2)
        XCTAssertTrue(model.isModified)
    }
    func testPreviewNumberHitAndDragConvertsRotatedTrimCoordinatesAndSnaps() throws {
        let field = SerialField(position: Point(5,5))
        let slot = Slot(sourcePageNumber: 1,origin: Point(10,15),size: Size(30,20),rotation: 90,
                        copyIndex: 0,artworkClip: Rect(x: 10,y: 15,width: 30,height: 20))
        var sheet = Sheet(size: Size(80,70),front: Side(slots: [slot]),back: Side())
        sheet.serialPlan = SerialNumberPlan(fields: [field],quantity: 1,capacity: 1,sheetCount: 1)
        let canvas = SheetCanvasView()
        canvas.configure(sheet: sheet,side: sheet.front,source: nil,overlays: .artworkOnly,highlighted: [])
        var selected: UUID?, moved: Point?
        canvas.selectSerial = { selected = $0 }
        canvas.moveSerial = { _,point in moved = point }
        func event(_ type: NSEvent.EventType,_ local: CGPoint) throws -> NSEvent {
            let p = local.applying(PDFPreviewDrawing.slotTransform(slot))
            return try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: 32+p.x*PDFPreviewDrawing.pointsPerMM,y: 32+p.y*PDFPreviewDrawing.pointsPerMM),
                modifierFlags: [],timestamp: 0,windowNumber: 0,context: nil,eventNumber: 1,clickCount: 1,pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown,CGPoint(x: 5.5,y: 5.5)))
        XCTAssertEqual(selected,field.id)
        canvas.mouseDragged(with: try event(.leftMouseDragged,CGPoint(x: 10.2,y: 11.8)))
        XCTAssertEqual(moved,Point(10,11))
        canvas.mouseUp(with: try event(.leftMouseUp,CGPoint(x: 10.2,y: 11.8)))
    }

    func testInitialFitWaitsForUsableScrollViewSize() {
        let scroll = PreviewScrollView(frame: .zero)
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.04; scroll.maxMagnification = 12
        let canvas = SheetCanvasView()
        canvas.configure(sheet: Sheet(size: Size(500,700),front: Side(),back: Side()),
                         side: Side(),source: nil,overlays: PreviewOverlays(),highlighted: [])
        scroll.documentView = canvas
        scroll.requestFit(); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification,1)
        scroll.setFrameSize(NSSize(width: 800,height: 600))
        scroll.requestFit(); scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.magnification,0.2)
        XCTAssertLessThan(scroll.magnification,0.4)
    }

    func testFileDropImportSelectionAndReordering() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var media = CGRect(x: 0,y: 0,width: 280,height: 420)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)),mediaBox: &media,nil))
        for _ in 0..<4 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let provider = NSItemProvider(item: url as NSURL,typeIdentifier: UTType.fileURL.identifier)
        let model = Workspace()
        XCTAssertTrue(model.acceptDrop([provider]))
        for _ in 0..<200 {
            if model.source != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.source?.pages.count,4)
        model.selectedPages = [1,2]
        model.moveSelected(up: false)
        XCTAssertEqual(model.order,[3,1,2,4])
        model.setIncluded(1,false)
        XCTAssertEqual(model.project.pages.map(\.number),[3,2,4])
        model.move(IndexSet(integer: 0),to: 3)
        XCTAssertEqual(model.project.pages.map(\.number),[2,3,4])
        model.includeAll(true)
        XCTAssertEqual(model.project.pages.map(\.number),[1,2,3,4])
        try await settle(model)
        XCTAssertTrue(model.plan.canExport)
    }

    func testRepeatModeLiveGridQuantityAndBookletGutterAreIndependent() async throws {
        let model = Workspace()
        model.setMode(.saddleStitch)
        model.project.sheet = SheetSpec(size: Size(100,80),gutter: 6,orientation: .landscape)
        model.project.settings = ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1)
        model.project.pages = [1,2].map { SourcePage(number: $0,trimSize: Size(30,20)) }
        model.project.stepAndRepeat.allowRotation = false
        model.setMode(.stepAndRepeat)
        XCTAssertEqual(model.project.sheet.gutter,0)
        try await settle(model)
        XCTAssertEqual(model.currentSheet?.repeatLayout?.copiesPerSheet,12)
        model.project.stepAndRepeat.quantity = 37
        try await settle(model)
        XCTAssertEqual(model.currentSheet?.repeatCount,4)
        model.project.stepAndRepeat.columns = 2
        try await settle(model)
        XCTAssertEqual(model.currentSheet?.repeatLayout?.copiesPerSheet,8)
        XCTAssertEqual(model.currentSheet?.repeatCount,5)
        model.project.sheet.gutter = 2
        model.setMode(.saddleStitch)
        XCTAssertEqual(model.project.sheet.gutter,6)
        try await settle(model)
        XCTAssertNil(model.currentSheet?.repeatLayout)
        XCTAssertEqual(model.plan.addedBlankPages,2)
        model.setMode(.stepAndRepeat)
        XCTAssertEqual(model.project.sheet.gutter,2)
        try await settle(model)
        XCTAssertEqual(model.plan.addedBlankPages,0)
    }

    func testExportIsGatedAndUsesFrozenPlanWhileSettingsChange() async throws {
        let model = Workspace()
        XCTAssertFalse(model.canExportNow)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf")
        var media = CGRect(x: 0,y: 0,width: 200,height: 300)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: input as CFURL)),mediaBox: &media,nil))
        for _ in 0..<8 { context.beginPDFPage(nil); context.endPDFPage() }; context.closePDF()
        model.open(input,confirmChanges: false)
        for _ in 0..<200 {
            if model.source != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await settle(model)
        XCTAssertTrue(model.canExportNow)
        let count = model.plan.totalPressSheets*2
        let output = directory.appendingPathComponent("result.pdf")
        model.overlays = .artworkOnly
        model.beginExport(to: .singlePDF(output))
        XCTAssertTrue(model.exporting); XCTAssertFalse(model.canExportNow)
        model.project.settings.bleed = 7
        for _ in 0..<200 {
            if !model.exporting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages,count)
        XCTAssertEqual(model.exportedFiles,[output])
        model.project.pages = []
        XCTAssertFalse(model.canExportNow)
        try await settle(model)
        model.beginExport(to: .singlePDF(directory.appendingPathComponent("invalid.pdf")))
        XCTAssertFalse(model.exporting); XCTAssertNotNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("invalid.pdf").path))
    }

    func testGeneratedBleedWarmsSourceCacheAndKeepsPlanSettingsSnapshot() async throws {
        let model = Workspace()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("generated.pdf")
        var media = CGRect(x: 0,y: 0,width: 90,height: 60)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: input as CFURL)),mediaBox: &media,nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil); context.setFillColor(CGColor(red: 1,green: 0,blue: 0,alpha: 1)); context.fill(media)
            context.endPDFPage()
        }
        context.closePDF()
        model.project.settings.generatedBleed.enabled = true
        model.setMode(.stepAndRepeat)
        model.open(input,confirmChanges: false)
        for _ in 0..<300 {
            if model.source != nil && !model.planning && !model.samplingBleed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.plan.generatedBleed.enabled)
        XCTAssertEqual(model.plan.generatedBleed.method,.automatic)
        let first = try XCTUnwrap(model.source?.edgeSamples.cached(page: 1))
        XCTAssertTrue(model.bleedSampleSummary?.contains("RGB") == true)
        XCTAssertTrue(model.canExportNow)
        model.project.settings.generatedBleed.tolerance = 0.1
        try await settle(model)
        XCTAssertTrue(model.source?.edgeSamples.cached(page: 1) === first)
        model.project.settings.generatedBleed.method = .solidColor
        model.project.settings.generatedBleed.color = .cmyk(1,0,0,0)
        try await settle(model)
        XCTAssertEqual(model.plan.generatedBleed.color,.cmyk(1,0,0,0))
    }

}
