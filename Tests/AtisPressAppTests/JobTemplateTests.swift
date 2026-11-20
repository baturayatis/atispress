import XCTest
import CoreGraphics
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class JobTemplateTests: XCTestCase {
    private func library() throws -> JobTemplateStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JobTemplateStore(directory: directory)
    }

    func testNamedTemplatePersistsAppliesUpdatesPlanAndPreservesDirtyFlag() async throws {
        let store = try library()
        let author = Workspace(templateStore: store)
        var machine = MachineProfile.heidelberg
        machine.rotation = .ninety
        machine.gap = 4
        author.project.machineProfile = machine
        author.project.settings.bleed = 1
        author.project.stepAndRepeat.quantity = 50
        author.project.stepAndRepeat.columns = 2
        author.project.includeBlankBacks = false
        author.overlays.pageNumbers = true
        try author.saveJobTemplate(name: "  Kartvizit  ")
        let id = try XCTUnwrap(author.selectedJobTemplateID)
        XCTAssertEqual(try store.load().first?.name, "Kartvizit")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [id.uuidString + ".json"])
        try author.renameJobTemplate(id, to: "Kartvizit ofset")

        let model = Workspace(templateStore: store)
        try model.refreshJobTemplates()
        let template = try XCTUnwrap(model.jobTemplates.first)
        XCTAssertEqual(template.id, id)
        XCTAssertEqual(template.name, "Kartvizit ofset")
        XCTAssertFalse(model.isModified)
        model.loadJobTemplate(template)
        XCTAssertFalse(model.isModified)
        XCTAssertEqual(model.selectedJobTemplateID, id)
        XCTAssertEqual(model.project.machineProfile, machine)
        XCTAssertEqual(model.project.settings.bleed, 1)
        XCTAssertEqual(model.project.stepAndRepeat.quantity, 50)
        XCTAssertEqual(model.project.stepAndRepeat.columns, 2)
        XCTAssertEqual(model.project.includeBlankBacks, false)
        XCTAssertTrue(model.overlays.pageNumbers)

        let input = store.directory.appendingPathComponent("kart.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 240, height: 156)
        let consumer = try XCTUnwrap(CGDataConsumer(url: input as CFURL))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        pdf.beginPDFPage(nil)
        pdf.fill(bounds)
        pdf.endPDFPage()
        pdf.closePDF()
        let receiver = Workspace(bookmarkCreator: {
            try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }, templateStore: store)
        receiver.open(input, confirmChanges: false)
        for _ in 0..<300 where receiver.loading || receiver.planning { try await Task.sleep(for: .milliseconds(10)) }
        let source = try XCTUnwrap(receiver.source)
        let pages = receiver.project.pages
        try receiver.saveProject(as: store.directory.appendingPathComponent("kart.atispress"))
        XCTAssertFalse(receiver.isModified)
        receiver.loadJobTemplate(template)
        for _ in 0..<300 where receiver.planning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(receiver.planning)
        XCTAssertTrue(receiver.source === source)
        XCTAssertEqual(receiver.project.pages, pages)
        XCTAssertFalse(receiver.isModified)
        XCTAssertEqual(receiver.currentSheet?.size, machine.size)
        XCTAssertEqual(receiver.currentSheet?.front.slots.first?.rotation, 90)
        receiver.project.settings.bleed = 2
        XCTAssertTrue(receiver.isModified)
        receiver.loadJobTemplate(template)
        XCTAssertFalse(receiver.isModified)
        receiver.project.includeBlankBacks = true
        receiver.loadJobTemplate(template)
        XCTAssertFalse(receiver.isModified)
        receiver.project.pages = []
        receiver.loadJobTemplate(template)
        XCTAssertTrue(receiver.isModified)

        try model.deleteJobTemplate(id)
        XCTAssertNil(model.selectedJobTemplateID)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testGangTemplateRemapsManualBlocksToCurrentArtwork() throws {
        let page = SourcePage(number: 1, trimSize: Size(80, 40))
        var project = Project(pages: [page], binding: .gang, sheet: SheetSpec(size: Size(510, 400)))
        var gang = GangSettings()
        var original = GangJob(sourceID: UUID(), name: "Kaynak", front: page)
        original.quantity = 123
        gang.jobs = [original]
        gang.mode = .manual
        gang.blocks = [GangBlock(jobID: original.id, origin: Point(25, 40), columns: 2)]
        project.gang = gang
        let template = JobTemplate(name: "Karışık", project: project, overlays: Workspace.defaultPreviewOverlays())
        XCTAssertTrue(template.settings.pages.isEmpty)
        XCTAssertNotEqual(template.settings.gang?.jobs.first?.sourceID, original.sourceID)

        let artwork = GangJob(sourceID: UUID(), name: "Güncel", front: page)
        project.gang?.jobs = [artwork]
        let applied = template.applying(to: project)
        let job = try XCTUnwrap(applied.gang?.jobs.first)
        XCTAssertEqual(job.sourceID, artwork.sourceID)
        XCTAssertEqual(job.name, artwork.name)
        XCTAssertEqual(job.quantity, 123)
        XCTAssertEqual(applied.gang?.mode, .manual)
        XCTAssertEqual(applied.gang?.blocks.first?.jobID, artwork.id)
        XCTAssertEqual(applied.gang?.blocks.first?.origin, Point(25, 40))
    }
}
