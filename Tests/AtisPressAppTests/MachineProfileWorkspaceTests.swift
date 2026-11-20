import XCTest
import ImpositionCore
import PDFEngine
import PDFKit
@testable import AtisPressApp

@MainActor
final class MachineProfileWorkspaceTests: XCTestCase {
    func testProfileLibrarySelectionAndProjectSnapshotRoundTrip() async throws {
        let suite = "MachineProfileTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = Workspace(uiDefaults: defaults)
        XCTAssertFalse(model.isModified)
        XCTAssertEqual(model.machineProfiles, [.heidelberg])
        var profile = MachineProfile(name: "Özel", size: Size(430, 310))
        profile.gripperEdge = .right
        profile.rotation = .ninety
        profile.gap = 4
        model.saveMachineProfile(profile)
        let url = folder.appendingPathComponent("job.atispress")
        try model.saveProject(as: url)

        let restarted = Workspace(uiDefaults: defaults)
        XCTAssertEqual(restarted.project.machineProfile, profile)
        XCTAssertFalse(restarted.isModified)
        var edited = profile
        edited.gap = 8
        restarted.saveMachineProfile(edited)
        XCTAssertEqual(Workspace(uiDefaults: defaults).project.machineProfile, edited)
        restarted.deleteMachineProfile(profile.id)
        let restored = Workspace(uiDefaults: defaults)
        XCTAssertNil(restored.project.machineProfile)
        XCTAssertEqual(restored.machineProfiles, [.heidelberg])
        try await restored.loadProject(at: url)
        XCTAssertEqual(restored.project.machineProfile, profile)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var state = try XCTUnwrap(legacy["state"] as? [String: Any])
        var project = try XCTUnwrap(state["project"] as? [String: Any])
        project.removeValue(forKey: "machineProfile")
        state["project"] = project
        legacy["state"] = state
        legacy["version"] = 26
        let file = try ProjectDocument.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(file.state.project.machineProfile)
        XCTAssertEqual(file.state.project.sheet, restored.project.sheet)
    }

    func testLivePlanExportsTheSameStockAndFaces() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 340, height: 226)
        let consumer = try XCTUnwrap(CGDataConsumer(url: input as CFURL))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for gray in [0.25, 0.75] {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(gray: gray, alpha: 1))
            pdf.fill(bounds)
            pdf.endPDFPage()
        }
        pdf.closePDF()

        let source = try await PDFSource.open(input)
        let model = Workspace()
        model.project.pages = source.pages.map(\.sourcePage)
        var profile = MachineProfile.heidelberg
        profile.faces = .workAndTurn
        profile.rotation = .ninety
        model.project.machineProfile = profile
        for _ in 0..<1_000 where model.planning { try await Task.sleep(for: .milliseconds(10)) }

        let sheet = try XCTUnwrap(model.currentSheet)
        XCTAssertTrue(model.plan.canExport, "\(model.plan.issues)")
        XCTAssertEqual(sheet.size, profile.size)
        XCTAssertEqual(Set(sheet.front.slots.compactMap(\.sourcePageNumber)), [1, 2])
        let result = try PDFExporter.export(plan: model.plan, source: source,
                                            destination: .singlePDF(folder.appendingPathComponent("output.pdf")),
                                            marks: model.project.exportMarks)
        let exported = try XCTUnwrap(PDFDocument(url: XCTUnwrap(result.files.first)))
        XCTAssertEqual(exported.pageCount, 2)
        for index in 0..<2 {
            let page = try XCTUnwrap(exported.page(at: index))
            let box = page.bounds(for: .mediaBox)
            XCTAssertEqual(box.width, sheet.size.width*72/25.4, accuracy: 0.01)
            XCTAssertEqual(box.height, sheet.size.height*72/25.4, accuracy: 0.01)
        }
    }
}
