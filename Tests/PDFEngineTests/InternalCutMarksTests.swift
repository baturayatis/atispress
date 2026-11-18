import XCTest
import CoreGraphics
import ImpositionCore
import PDFEngine

final class InternalCutMarksTests: XCTestCase {
    private let trim = Size(150, 50)

    private func settings() -> InternalCutMarks {
        var cuts = InternalCutMarks()
        cuts.horizontal.enabled = true
        cuts.vertical.enabled = true
        return cuts
    }

    func testCentersApplyToEveryRepeatCopyAndStayOutsideTrim() throws {
        let pages = [SourcePage(number: 1, trimSize: trim), SourcePage(number: 2, trimSize: trim)]
        var project = Project(pages: pages, sheet: SheetSpec(size: Size(340, 100), gutter: 8, orientation: .landscape),
                              settings: ImpositionSettings(bleed: 0, cropMarkLength: 5, cropMarkOffset: 3),
                              stepAndRepeat: StepAndRepeatSettings(columns: 2, rows: 1, allowRotation: false))
        project.internalCutJobs = [1: settings()]
        let plan = ImpositionPlanner.plan(project)
        XCTAssertTrue(plan.canExport, "\(plan.issues)")
        let sheet = try XCTUnwrap(plan.sheets.first)
        for side in [sheet.front, sheet.back] {
            let marks = PDFExportMarkRenderer.geometry(side: side, sheet: sheet, settings: .none).segments
            XCTAssertEqual(marks.count, 7, "Two horizontal center lines share a single tick in the gutter")
            for slot in side.slots {
                XCTAssertTrue(marks.contains { $0.start.y == slot.y + 25 && $0.end.y == slot.y + 25 })
                let vertical = marks.filter { $0.start.x == slot.x + 75 && $0.end.x == slot.x + 75 }
                XCTAssertEqual(vertical.count, 2)
                XCTAssertTrue(vertical.allSatisfy { $0.end.y < slot.y || $0.start.y > slot.y + slot.size.height })
            }
        }
    }

    func testManualGangRotationCustomCutsAndJobIsolation() throws {
        let first = SourcePage(number: 1, trimSize: trim)
        let second = SourcePage(number: 2, trimSize: trim)
        let sourceID = UUID()
        var job = GangJob(sourceID: sourceID, name: "Döndürülmüş", front: first)
        job.bleed = 0
        var cuts = settings()
        cuts.horizontal.position = .custom
        cuts.horizontal.offsets = [10, 30, 30]
        cuts.vertical.position = .custom
        cuts.vertical.offsets = [20, 100]
        job.internalCuts = cuts
        var other = GangJob(sourceID: sourceID, name: "İşaretsiz", front: second)
        other.bleed = 0
        var gang = GangSettings()
        gang.mode = .manual
        gang.jobs = [job, other]
        gang.blocks = [
            GangBlock(jobID: job.id, origin: Point(20, 20), rotated: true),
            GangBlock(jobID: other.id, origin: Point(100, 20))
        ]
        var project = Project(pages: [first, second], binding: .gang,
                              sheet: SheetSpec(size: Size(280, 200), orientation: .landscape),
                              settings: ImpositionSettings(bleed: 0))
        project.gang = gang
        let plan = ImpositionPlanner.plan(project)
        XCTAssertTrue(plan.canExport, "\(plan.issues)")
        let sheet = try XCTUnwrap(plan.sheets.first)
        let marks = PDFExportMarkRenderer.geometry(side: sheet.front, sheet: sheet, settings: .none).segments
        XCTAssertEqual(marks.count, 8)
        XCTAssertEqual(marks.filter { $0.start.x == $0.end.x }.map(\.start.x).sorted(), [30, 30, 50, 50])
        XCTAssertEqual(marks.filter { $0.start.y == $0.end.y }.map(\.start.y).sorted(), [70, 70, 150, 150])
        project.gang?.jobs[0].internalCuts?.vertical.offsets = [150]
        XCTAssertFalse(ImpositionPlanner.plan(project).canExport)
    }

    func testVectorOutputMatchesProductionMarkDrawingAndKeepsArtworkClear() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.pdf")
        let factor = PDFPreviewDrawing.pointsPerMM
        var media = CGRect(x: 0, y: 0, width: trim.width * factor, height: trim.height * factor)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: input as CFURL)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(media)
        context.endPDFPage()
        context.closePDF()
        let source = try await PDFSource.open(input)
        var project = Project(pages: source.pages.map(\.sourcePage),
                              sheet: SheetSpec(size: Size(190, 90), margins: Insets(left: 10, right: 10, top: 10, bottom: 10), orientation: .landscape),
                              settings: ImpositionSettings(bleed: 0),
                              stepAndRepeat: StepAndRepeatSettings(columns: 1, rows: 1, allowRotation: false))
        project.internalCutJobs = [1: settings()]
        let plan = ImpositionPlanner.plan(project)
        let sheet = try XCTUnwrap(plan.sheets.first)
        var marks = ExportMarks.none
        marks.lineWidth = 1
        let report = try PDFExporter.export(plan: plan, source: source,
                                            destination: .singlePDF(folder.appendingPathComponent("out.pdf")), marks: marks)
        let pdf = try XCTUnwrap(CGPDFDocument(report.files[0] as CFURL))
        let page = try XCTUnwrap(pdf.page(at: 1))
        let slot = try XCTUnwrap(sheet.front.slots.first)
        let geometry = PDFExportMarkRenderer.geometry(side: sheet.front, sheet: sheet, settings: marks)
        XCTAssertEqual(geometry.segments.count, 4)
        func sample(_ point: Point, from drawing: (CGContext) -> Void) throws -> UInt8 {
            let image = try XCTUnwrap(CGContext(data: nil, width: 5, height: 5, bitsPerComponent: 8,
                                               bytesPerRow: 5, space: CGColorSpaceCreateDeviceGray(),
                                               bitmapInfo: CGImageAlphaInfo.none.rawValue))
            image.setFillColor(CGColor(gray: 1, alpha: 1))
            image.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
            image.translateBy(x: 2.5, y: 2.5)
            image.scaleBy(x: 16, y: 16)
            image.translateBy(x: -point.x, y: -point.y)
            drawing(image)
            return try XCTUnwrap(image.data).assumingMemoryBound(to: UInt8.self)[12]
        }
        func exported(_ image: CGContext) {
            image.scaleBy(x: 1 / factor, y: 1 / factor)
            image.drawPDFPage(page)
        }
        for tick in geometry.segments {
            let center = Point((tick.start.x + tick.end.x) / 2, (tick.start.y + tick.end.y) / 2)
            let preview = try sample(center) {
                PDFExportMarkRenderer.draw(side: sheet.front, sheet: sheet, in: $0, settings: marks, info: "")
            }
            XCTAssertLessThan(preview, 80)
            XCTAssertLessThan(try sample(center, from: exported), 80)
        }
        XCTAssertGreaterThan(try sample(Point(slot.x + 75, slot.y + 25), from: exported), 150)
    }
}
