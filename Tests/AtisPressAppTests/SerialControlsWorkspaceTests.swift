import XCTest
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class SerialControlsWorkspaceTests: XCTestCase {
    private func settle(_ model: Workspace) async throws {
        for _ in 0..<500 {
            if !model.planning && !model.autoArranging { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Planner did not settle")
    }
    private func model() async throws -> Workspace {
        let model = Workspace()
        model.project.sheet = SheetSpec(size: Size(100,100),gutter: 1)
        model.project.settings = ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1)
        model.project.stepAndRepeat = StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 500)
        model.project.pages = [1,2].map { SourcePage(number: $0,trimSize: Size(20,30)) }
        model.addSerialField()
        try await settle(model)
        return model
    }
    func testEndNumberSetsSharedQuantityAndQuantityUpdatesEnd() async throws {
        let model = try await model(), id = model.project.serialFields[0].id
        model.project.serialFields[0].showsEndNumber = true
        model.setSerialEnd("750",id: id)
        XCTAssertEqual(model.project.stepAndRepeat.quantity,750)
        try await settle(model)
        XCTAssertEqual(model.currentSheet?.repeatCount,188)
        XCTAssertEqual(model.currentSheet?.excessCopies,2)
        model.project.stepAndRepeat.quantity = 501
        XCTAssertEqual(model.project.serialFields[0].value(at: model.serialQuantity(job: 0)-1),501)
        try await settle(model)
        XCTAssertEqual(model.serialSheetCount(job: 0),126)
        XCTAssertEqual(model.currentSheet?.excessCopies,3)
        model.project.serialFields[0].step = 2
        model.setSerialEnd("1000",id: id)
        XCTAssertNotNil(model.serialInputErrors[id])
        XCTAssertEqual(model.project.stepAndRepeat.quantity,501)
        model.setSerialEnd("999",id: id)
        XCTAssertEqual(model.project.stepAndRepeat.quantity,500)
        XCTAssertNil(model.serialInputErrors[id])
    }
    func testDigitsIncreaseImmediatelyAndManualWidthStaysFixedWithWarning() async throws {
        let model = try await model(), id = model.project.serialFields[0].id
        model.project.stepAndRepeat.quantity = 10_001
        XCTAssertEqual(model.project.serialFields[0].digits,5)
        XCTAssertEqual(model.project.serialFields[0].digitNote(quantity: 10_001),"Basamak 5'e çıkarıldı")
        try await settle(model)
        model.setSerialDigits(4,id: id)
        XCTAssertEqual(model.project.serialFields[0].digits,4)
        XCTAssertTrue(model.project.serialFields[0].digitsAreManual)
        XCTAssertTrue(model.plan.displayIssues.contains { $0.message.contains("elle 4") })
        XCTAssertEqual(model.currentSheet?.serialPlan?.fields.first?.text(at: 10_000),"10001")
        model.project.serialFields[0].digitsAreManual = false
        XCTAssertEqual(model.project.serialFields[0].digits,5)
    }
    func testSheetSelectionDefaultsAndReturnToAutomaticKeepOtherManualValues() async throws {
        let model = Workspace()
        XCTAssertEqual(model.sheetPreset,Workspace.automaticSheetTitle)
        XCTAssertEqual(model.project.autoLayout?.sheetSelection,.automatic)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.sra3.size)
        model.setProduction(.offset)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.cm33x48.size)
        model.project.pages = [SourcePage(number: 1,trimSize: Size(85,55))]
        model.project.sheet.size = SheetPreset.cm35x50.size
        model.sheetPreset = "35×50"
        model.project.sheet.margins.left = 17
        try await settle(model)
        XCTAssertEqual(model.project.autoLayout?.sheetSelection,.fixed)
        model.returnToAutomaticSheet()
        try await settle(model)
        XCTAssertEqual(model.sheetPreset,Workspace.automaticSheetTitle)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.cm33x48.size)
        XCTAssertEqual(model.project.sheet.margins.left,17)
        model.setSheetSelection(.efficient)
        try await settle(model)
        XCTAssertEqual(model.project.sheet.size,SheetPreset.cm70x100.size)
        XCTAssertEqual(model.project.autoLayout?.sheetSelection,.efficient)
    }
}
