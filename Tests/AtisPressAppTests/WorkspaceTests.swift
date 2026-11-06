import XCTest
import AppKit
import UniformTypeIdentifiers
import ImpositionCore
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

}
