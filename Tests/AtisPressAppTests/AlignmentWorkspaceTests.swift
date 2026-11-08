import XCTest
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor
final class AlignmentWorkspaceTests: XCTestCase {
    func testNewProjectFiveByFiveOnLandscape33x48IsCenteredOnBothAxes() throws {
        var p = Workspace.newProject()
        p.pages = [SourcePage(number:1,trimSize:Size(86.7,54),availableBleed:3)]
        p.sheet = SheetSpec(preset:.cm33x48,margins:Insets(left:10,right:10,top:10,bottom:10),gripperEdge:.bottom,gripperWidth:0,gutter:0,orientation:.landscape)
        p.stepAndRepeat.columns = 5; p.stepAndRepeat.rows = 5
        let plan = ImpositionPlanner.plan(p); XCTAssertTrue(plan.canExport)
        let sheet = try XCTUnwrap(plan.sheets.first),slots = sheet.front.slots
        let left = slots.map(\.x).min()!-10,right = 480-10-slots.map { $0.x+$0.size.width }.max()!
        let bottom = slots.map(\.y).min()!-10,top = 330-10-slots.map { $0.y+$0.size.height }.max()!
        XCTAssertEqual(left,right,accuracy:0.01)
        XCTAssertEqual(bottom,top,accuracy:0.01)
    }
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<1000 {
            if !model.loading && !model.planning && !model.autoArranging && !model.samplingBleed { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Layout did not settle")
    }
    func testLaunchAndNewProjectDefaultCenterAndSchema12KeepsLegacyPlacement() throws {
        let model = Workspace()
        XCTAssertEqual(model.project.blockAlignment,.center)
        XCTAssertEqual(Workspace.newProject().blockAlignment,.center)
        let current = ProjectDocument(state:model.state)
        XCTAssertEqual(current.version,ProjectDocument.currentVersion)
        XCTAssertEqual(try ProjectDocument.decode(current.encoded()).state.project.blockAlignment,.center)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with:current.encoded()) as? [String:Any])
        data["version"] = 11
        var state = try XCTUnwrap(data["state"] as? [String:Any])
        var project = try XCTUnwrap(state["project"] as? [String:Any])
        project.removeValue(forKey:"alignment"); state["project"] = project; data["state"] = state
        let old = try ProjectDocument.decode(JSONSerialization.data(withJSONObject:data)).state.project
        XCTAssertEqual(old.blockAlignment,.gripper)
        XCTAssertNil(old.alignment)
        XCTAssertTrue(old.autoLayout!.manualFields.contains(.alignment))
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(old)),old)
    }
    func testResetConfirmationCancelAndApprovalResetAllOwnershipAndValues() async throws {
        let model = Workspace()
        model.project.pages = [SourcePage(number:1,trimSize:Size(86.7,54),availableBleed:3)]
        model.project.sheet = SheetSpec(size:Size(600,800),margins:Insets(left:1,right:2,top:3,bottom:4),gripperEdge:.left,gripperWidth:7,gutter:13,orientation:.portrait)
        model.project.blockAlignment = .gripper
        model.project.stepAndRepeat.columns = 1; model.project.stepAndRepeat.rows = 1
        model.project.stepAndRepeat.allowRotation = false; model.project.stepAndRepeat.quantity = 123
        model.project.serialFields = [SerialField(prefix:"TEST-")]
        model.project.settings.bleed = 0; model.project.settings.cropMarkOffset = 0; model.project.settings.cropMarkLength = 0
        model.project.exportMarks = .none
        model.project.autoLayout?.manualFields = Set(AutoLayoutField.allCases)
        model.project.autoLayout?.sheetSelection = .fixed
        try await settle(model)
        let before = model.project
        var prompts = 0
        model.requestAutomaticLayout { message in
            prompts += 1; XCTAssertEqual(message,"Elle yapılan ayarlar sıfırlanacak."); return false
        }
        XCTAssertEqual(prompts,1); XCTAssertEqual(model.project,before); XCTAssertFalse(model.autoArranging)
        model.requestAutomaticLayout { _ in true }
        try await settle(model)
        XCTAssertTrue(model.project.autoLayout!.manualFields.isEmpty)
        XCTAssertEqual(model.project.autoLayout!.automaticFields,Set(AutoLayoutField.allCases))
        XCTAssertEqual(model.project.autoLayout?.sheetSelection,.automatic)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.sra3.size)
        XCTAssertEqual(model.project.sheet.margins,Insets(left:10,right:10,top:10,bottom:10))
        XCTAssertEqual(model.project.sheet.gripperEdge,.bottom); XCTAssertEqual(model.project.sheet.gripperWidth,0)
        XCTAssertEqual(model.project.sheet.gutter,0); XCTAssertEqual(model.project.stepAndRepeat.arrangement,.adjacent)
        XCTAssertEqual(model.project.blockAlignment,.center)
        XCTAssertTrue(model.project.stepAndRepeat.allowRotation); XCTAssertNil(model.project.stepAndRepeat.columns); XCTAssertNil(model.project.stepAndRepeat.rows)
        XCTAssertEqual(model.project.settings.bleed,3); XCTAssertTrue(model.project.exportMarks.crop)
        XCTAssertEqual(model.project.settings.cropMarkLength,5)
        XCTAssertEqual(model.project.stepAndRepeat.quantity,123); XCTAssertEqual(model.project.serialFields,before.serialFields)
        XCTAssertEqual(model.autoLabel("Hizalama",.alignment),"Hizalama · Otomatik")
    }
    func testPerFieldResetKeepsOtherManualFieldsAndAlignmentUpdatesPreview() async throws {
        let model = Workspace()
        model.project.pages = [SourcePage(number:1,trimSize:Size(86.7,54),availableBleed:3)]
        model.project.sheet.margins.left = 3; model.project.sheet.margins.right = 17
        model.project.blockAlignment = .gripper
        try await settle(model)
        model.returnToAutomatic(.marginLeft)
        try await settle(model)
        XCTAssertEqual(model.project.sheet.margins.left,10)
        XCTAssertEqual(model.project.sheet.margins.right,17)
        XCTAssertFalse(model.isManual(.marginLeft)); XCTAssertTrue(model.isManual(.marginRight))
        XCTAssertEqual(model.project.blockAlignment,.gripper)
        let oldY = model.plan.sheets.first?.front.slots.first?.y
        model.returnToAutomatic(.alignment)
        try await settle(model)
        XCTAssertEqual(model.project.blockAlignment,.center)
        XCTAssertNotEqual(model.plan.sheets.first?.front.slots.first?.y,oldY)
        XCTAssertEqual(model.project.sheet.margins.right,17)
    }

}
