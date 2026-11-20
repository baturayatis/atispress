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
        machine.columns = 2
        machine.rows = 1
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
        try author.updateJobTemplate(id, name: "Kartvizit ofset", expectedSize: nil)

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

    func testExpectedSizeWarnsOnOpenAndTemplateSelectionAndAllowsContinuation() async throws {
        let store = try library()
        let model = Workspace(templateStore: store)
        try model.saveJobTemplate(name: "A4", expectedSize: Size(210, 297))
        let template = try XCTUnwrap(model.jobTemplates.first)
        let matching = SourcePage(number: 1, trimSize: Size(297.05, 210))
        let different = SourcePage(number: 2, trimSize: Size(85, 55))
        XCTAssertNil(template.mismatch(in: [matching]))
        XCTAssertEqual(template.mismatch(in: [matching, different])?.page, 2)
        XCTAssertNil(JobTemplate.inferredSize(from: [matching, different]))
        XCTAssertEqual(JobTemplate.inferredSize(from: [matching]), matching.trimSize)

        let input = store.directory.appendingPathComponent("card.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 240, height: 156)
        let consumer = try XCTUnwrap(CGDataConsumer(url: input as CFURL))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        pdf.beginPDFPage(nil)
        pdf.endPDFPage()
        pdf.closePDF()

        var warnings: [JobTemplateSizeMismatch] = []
        model.open(input, confirmChanges: false, confirmTemplateSize: { warnings.append($0); return false })
        for _ in 0..<300 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.source)
        XCTAssertNil(model.error)
        XCTAssertEqual(warnings.map(\.expected), [Size(210, 297)])

        model.open(input, confirmChanges: false, confirmTemplateSize: { warnings.append($0); return true })
        for _ in 0..<300 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        let source = try XCTUnwrap(model.source)
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(warnings.last?.actual, source.pages.first?.sourcePage.trimSize)

        var other = template
        other.id = UUID()
        other.settings.settings.bleed = 9
        let oldBleed = model.project.settings.bleed
        model.loadJobTemplate(other, confirmTemplateSize: { warnings.append($0); return false })
        XCTAssertEqual(model.project.settings.bleed, oldBleed)
        model.loadJobTemplate(other, confirmTemplateSize: { warnings.append($0); return true })
        XCTAssertEqual(model.project.settings.bleed, 9)
        XCTAssertTrue(model.source === source)
        XCTAssertEqual(warnings.count, 4)
    }

    func testJSONTransferKeepsExpectedSizeAndSettingsAndReadsLegacyFiles() throws {
        let store = try library()
        let model = Workspace(templateStore: store)
        model.project.settings.bleed = 2
        try model.saveJobTemplate(name: "Kart", expectedSize: Size(85, 55))
        let template = try XCTUnwrap(model.jobTemplates.first)
        let exported = store.directory.appendingPathComponent("kart.json")
        try model.exportJobTemplate(template.id, to: exported)

        let other = Workspace(templateStore: try library())
        let imported = try other.importJobTemplate(from: exported)
        XCTAssertEqual(imported.id, template.id)
        XCTAssertEqual(imported.expectedSize, Size(85, 55))
        XCTAssertEqual(imported.settings, template.settings)
        XCTAssertEqual(imported.overlays, template.overlays)
        XCTAssertNotEqual(try other.importJobTemplate(from: exported).id, template.id)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any])
        json.removeValue(forKey: "expectedSize")
        try JSONSerialization.data(withJSONObject: json).write(to: exported)
        XCTAssertNil(try other.importJobTemplate(from: exported).expectedSize)
        let count = other.jobTemplates.count
        json["expectedSize"] = ["width": -1, "height": 55]
        try JSONSerialization.data(withJSONObject: json).write(to: exported)
        XCTAssertThrowsError(try other.importJobTemplate(from: exported))
        try Data("[]".utf8).write(to: exported)
        XCTAssertThrowsError(try other.importJobTemplate(from: exported))
        XCTAssertEqual(other.jobTemplates.count, count)
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
