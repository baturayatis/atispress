import XCTest
@testable import ImpositionCore

final class FoldGutterTests: XCTestCase {
    func testFoldGeometryIgnoresLegacyGuttersForEverySignatureAndTurnStyle() throws {
        for binding in [BindingMethod.saddleStitch,.perfectBound,.sewn] {
            for signature in [SignatureSize.four,.eight,.sixteen,.thirtyTwo,.automatic] {
                for turn in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
                    var p = Project(pages:(1...32).map { SourcePage(number:$0,trimSize:Size(40,60),availableBleed:3) },
                        binding:binding,sheet:SheetSpec(preset:.cm70x100),
                        settings:ImpositionSettings(signatureSize:signature,turnMethod:turn))
                    let contiguous = ImpositionPlanner.plan(p)
                    XCTAssertTrue(contiguous.canExport)
                    p.sheet.gutter = 6
                    let legacy = ImpositionPlanner.plan(p)
                    XCTAssertEqual(legacy.sheets,contiguous.sheets,"\(binding), \(signature), \(turn)")
                    XCTAssertEqual(legacy.addedBlankPages,contiguous.addedBlankPages)
                    XCTAssertEqual(p.sheet.gutter,6,"Planning must not mutate stored flat-job intent")
                }
            }
        }
    }
    func testAutomaticBookletNeverReintroducesSixMillimetresEvenWithManualFlatGutter() {
        var p = Project(pages:(1...106).map { SourcePage(number:$0,trimSize:Size(148,210)) },binding:.perfectBound,
            sheet:SheetSpec(preset:.a4,margins:Insets(),gutter:6,orientation:.landscape))
        p.exportMarks = .none; p.settings.bleed = 0
        var state = AutoLayoutSettings(); state.sheetSelection = .fixed
        state.manualFields = [.sheetSize,.orientation,.marginLeft,.marginRight,.marginTop,.marginBottom,.gripperWidth,.gutter,.exportCrop,.bleed]
        p.autoLayout = state
        let result = SmartAutoLayout.arrange(p)
        XCTAssertEqual(result.project.sheet.gutter,0)
        XCTAssertTrue(result.plan.canExport,"\(result.plan.issues)")
        XCTAssertEqual(result.plan.sheets.count,27)
    }
    func testFitDiagnosticsUseZeroFoldGapEvenIfSavedGutterIsPositive() {
        var p = Project(pages:(1...106).map { SourcePage(number:$0,trimSize:Size(148,210)) },binding:.saddleStitch,
            sheet:SheetSpec(preset:.a4,margins:Insets(left:1,right:1),gutter:6,orientation:.landscape))
        p.settings.bleed = 0; p.exportMarks = .none
        let plan = ImpositionPlanner.plan(p)
        XCTAssertFalse(plan.canExport)
        XCTAssertTrue(plan.issues.contains { $0.message.contains("gereken 298.00×210.00") })
        XCTAssertFalse(plan.issues.contains { $0.message.contains("302.00") || $0.message.contains("304.00") })
    }
}
