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
        profile.columns = 2
        profile.rows = 1
        profile.gap = 4
        model.saveMachineProfile(profile)
        let url = folder.appendingPathComponent("job.atispress")
        try model.saveProject(as: url)

        defaults.set(profile.id.uuidString, forKey: "selectedMachineProfile")
        let restarted = Workspace(uiDefaults: defaults)
        XCTAssertNil(restarted.project.machineProfile)
        XCTAssertEqual(restarted.project.sheet, Workspace.newProject().sheet)
        XCTAssertEqual(restarted.sheetPreset, Workspace.automaticSheetTitle)
        XCTAssertTrue(restarted.machineProfiles.contains(profile))
        XCTAssertFalse(restarted.isModified)
        model.createNewProject()
        XCTAssertNil(model.project.machineProfile)
        XCTAssertEqual(model.project.sheet, Workspace.newProject().sheet)
        XCTAssertEqual(model.sheetPreset, Workspace.automaticSheetTitle)
        var edited = profile
        edited.gap = 8
        restarted.saveMachineProfile(edited)
        let anotherWindow = Workspace(uiDefaults: defaults)
        XCTAssertNil(anotherWindow.project.machineProfile)
        XCTAssertTrue(anotherWindow.machineProfiles.contains(edited))
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

    func testProfileDefaultsToOneByOneAndRetainsLastPreviewWhenGridDoesNotFit() async throws {
        let suite = "MachineGridTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Workspace(uiDefaults: defaults)
        model.project.pages = [SourcePage(number: 1, trimSize: Size(118, 80))]
        model.selectMachineProfile(.heidelberg)
        for _ in 0..<100 where model.planning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.currentSheet?.front.slots.count, 1)

        model.project.machineProfile?.columns = 2
        model.project.machineProfile?.rows = 2
        for _ in 0..<100 where model.planning { try await Task.sleep(for: .milliseconds(5)) }
        let last = try XCTUnwrap(model.currentSheet)
        XCTAssertEqual(last.front.slots.count, 4)
        for columns in [10, 20, 2] {
            model.project.machineProfile?.columns = columns
            for _ in 0..<100 where model.planning { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(model.currentSheet?.front.slots, last.front.slots)
            XCTAssertEqual(model.plan.canExport, columns == 2)
            if columns != 2 {
                XCTAssertTrue(model.plan.sheets.isEmpty)
                XCTAssertTrue(model.plan.issues.contains { $0.code == .exceedsSheet && $0.severity == .warning })
                XCTAssertTrue(model.highlightedSlots.isEmpty)
            }
        }
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
        model.project.settings.bleed = 9
        model.project.settings.cropMarkOffset = 1
        var profile = MachineProfile.heidelberg
        profile.faces = .workAndTurn
        profile.rotation = .ninety
        profile.columns = 2
        profile.rows = 1
        model.project.machineProfile = profile
        for _ in 0..<1_000 where model.planning { try await Task.sleep(for: .milliseconds(10)) }

        let sheet = try XCTUnwrap(model.currentSheet)
        XCTAssertTrue(model.plan.canExport, "\(model.plan.issues)")
        XCTAssertEqual(sheet.size, profile.size)
        XCTAssertEqual(sheet.front.slots.count, 2)
        XCTAssertTrue(sheet.front.slots.allSatisfy { $0.y == 30 && $0.artworkClip?.origin.y == 21 })
        let tick = try XCTUnwrap(sheet.front.marks.first { $0.kind == .crop && $0.start.y == 30 && $0.end.y == 30 })
        XCTAssertEqual(Set(sheet.front.slots.compactMap(\.sourcePageNumber)), [1, 2])
        let printed = PDFExportMarkRenderer.geometry(side: sheet.front, sheet: sheet, settings: model.project.exportMarks)
        let printedTick = try XCTUnwrap(printed.segments.first {
            $0.kind == .crop && $0.start.y == 30 && $0.end.y == 30 &&
                $0.start.x == min(tick.start.x,tick.end.x) && $0.end.x == max(tick.start.x,tick.end.x)
        })
        XCTAssertEqual(printedTick.start.y, 30)
        XCTAssertEqual(printedTick.end.y, 30)
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
            let cgPage = try XCTUnwrap(page.pageRef)
            let scale = 20.0
            let mmToPoints = 72.0/25.4
            var pixels = [UInt8](repeating: 255, count: 64)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                                        bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
                context.scaleBy(x: scale/mmToPoints, y: scale/mmToPoints)
                let x = (tick.start.x+tick.end.x)/2*mmToPoints
                let y = 30*mmToPoints
                context.translateBy(x: -x+4*mmToPoints/scale, y: -y+4*mmToPoints/scale)
                context.drawPDFPage(cgPage)
            }
            XCTAssertLessThan(pixels[24..<40].min() ?? 255, 128, "PDF must print the horizontal crop tick at y = 30 mm")
            XCTAssertEqual(pixels[0..<8].min(), 255)
            XCTAssertEqual(pixels[56..<64].min(), 255)
        }
    }
}
