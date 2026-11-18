import XCTest
import PDFKit
import ImpositionCore
import PDFEngine

final class ArtworkSeparationTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("artboard.pdf")
        let pt = PDFPreviewDrawing.pointsPerMM
        var media = CGRect(x: 0, y: 0, width: 200 * pt, height: 150 * pt)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.scaleBy(x: pt, y: pt)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        for (index, box) in [CGRect(x: 10, y: 84, width: 65, height: 45),
                             CGRect(x: 100, y: 84, width: 65, height: 45),
                             CGRect(x: 32, y: 15, width: 104, height: 43)].enumerated() {
            context.setFillColor(CGColor(gray: CGFloat(index + 1) / 5, alpha: 1))
            context.fill(box)
            context.fill(box.insetBy(dx: 2, dy: 2))
        }
        context.endPDFPage()
        context.closePDF()
        return (directory, url)
    }

    func testGeometryFindsIrregularRowsAndNeverAssignsFaces() async throws {
        let (_, url) = try fixture()
        let source = try await PDFSource.open(url)
        let proposals = source.guides.artworkCandidates(size: source.pages[0].trimSize)
        XCTAssertEqual(proposals.count, 3)
        XCTAssertTrue(proposals.allSatisfy { $0.assignment == nil })
        let boxes = proposals.map(\.crop).sorted { $0.origin.x < $1.origin.x }
        XCTAssertEqual(boxes.map { Int($0.origin.x.rounded()) }, [10, 32, 100])
        XCTAssertEqual(boxes.map { Int($0.origin.y.rounded()) }, [84, 15, 84])
    }

    func testManualCorrectionDuplexAndVectorClippingFromRotatedArtboard() async throws {
        let (directory, url) = try fixture()
        let rotatedURL = directory.appendingPathComponent("rotated.pdf")
        let rotated = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(rotated.page(at: 0))
        page.rotation = 90
        XCTAssertTrue(rotated.write(to: rotatedURL))
        let source = try await PDFSource.open(rotatedURL)
        let size = source.pages[0].trimSize
        XCTAssertEqual(size.width, 150, accuracy: 0.001)
        XCTAssertEqual(size.height, 200, accuracy: 0.001)
        var draft = ArtworkSeparation()
        draft.regions = source.guides.artworkCandidates(size: size)
        XCTAssertEqual(draft.regions.count, 3)
        let twins = draft.regions.indices.filter { abs(draft.regions[$0].crop.size.height - 65) < 0.01 }
        XCTAssertEqual(twins.count, 2)
        let front = try XCTUnwrap(twins.first), back = try XCTUnwrap(twins.last)
        for i in [front, back] {
            draft.regions[i].crop.size = Size(45, 65)
            draft.regions[i].bleed = Insets(left: 2, right: 2, top: 3, bottom: 3)
        }
        draft.regions[front].assignment = SplitCell(product: 1)
        XCTAssertNotNil(draft.validation(size: size), "Unreviewed regions cannot be silently omitted")
        draft.regions[back].assignment = SplitCell(product: 1, side: .back)
        let remaining = try XCTUnwrap(draft.regions.indices.first { !twins.contains($0) })
        draft.regions[remaining].assignment = SplitCell(product: nil)
        XCTAssertNil(draft.validation(size: size))

        var preparation = SourcePreparationSettings()
        preparation.separation = draft
        let prepared = try await source.prepared(preparation)
        XCTAssertEqual(prepared.pages.map(\.trimSize), [Size(41, 59), Size(41, 59)])
        XCTAssertEqual(prepared.pages.compactMap(\.availableBleed), [2, 2])
        let preparedDocument = try XCTUnwrap(CGPDFDocument(prepared.url as CFURL))
        XCTAssertFalse(PDFGuideDetector.inspect(preparedDocument).hasImages)

        for method in [TurnMethod.sheetwise, .workAndTurn, .workAndTumble] {
            let pages = prepared.pages.map(\.sourcePage)
            var project = Project(pages: pages, binding: .gang, sheet: SheetSpec(size: Size(230, 200)),
                                  settings: ImpositionSettings(turnMethod: method))
            var gang = GangSettings()
            var job = GangJob(sourceID: preparation.sourceID, name: "Kart", front: pages[0], back: pages[1])
            job.quantity = 1
            job.bleed = 2
            gang.jobs = [job]
            project.gang = gang
            let plan = ImpositionPlanner.plan(project)
            XCTAssertTrue(plan.canExport, "\(plan.issues)")
            let sheet = try XCTUnwrap(plan.sheets.first)
            let frontSlot = try XCTUnwrap(sheet.front.slots.first { $0.itemSide == .front })
            let backSlot = try XCTUnwrap(sheet.back.slots.first { $0.copyIndex == frontSlot.copyIndex && $0.itemSide == .back })
            XCTAssertEqual(backSlot.size, frontSlot.size)
            XCTAssertEqual(backSlot.x, sheet.backFlipsX ? sheet.size.width - frontSlot.x - frontSlot.size.width : frontSlot.x, accuracy: 0.000001)
            XCTAssertEqual(backSlot.y, sheet.backFlipsX ? frontSlot.y : sheet.size.height - frontSlot.y - frontSlot.size.height, accuracy: 0.000001)
            let output = directory.appendingPathComponent("\(method.rawValue).pdf")
            let report = try PDFExporter.export(plan: plan, source: prepared, destination: .singlePDF(output), marks: .none)
            XCTAssertEqual(report.pageCount, 2)
            XCTAssertFalse(PDFGuideDetector.inspect(try XCTUnwrap(CGPDFDocument(output as CFURL))).hasImages)
        }
    }

    func testManualBoundariesRejectOverlapAndIncompletePairs() {
        var draft = ArtworkSeparation()
        draft.regions = [
            ArtworkRegion(crop: Rect(x: 2, y: 2, width: 30, height: 30), assignment: SplitCell(product: 1)),
            ArtworkRegion(crop: Rect(x: 24, y: 7, width: 30, height: 30), assignment: SplitCell(product: 1, side: .back))
        ]
        let size = Size(100, 100)
        XCTAssertNotNil(draft.validation(size: size))
        draft.regions[1].crop.origin.x = 50
        XCTAssertNil(draft.validation(size: size))
        draft.regions[1].crop.size.width = 32
        XCTAssertNotNil(draft.validation(size: size))
        draft.regions[1].crop.size.width = 30
        draft.regions[0].assignment = SplitCell(product: nil)
        XCTAssertNotNil(draft.validation(size: size))
    }
}
