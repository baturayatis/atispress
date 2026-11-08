import XCTest
@testable import ImpositionCore

final class BindingAllowanceTests: XCTestCase {
    private func project(_ behavior: BindingAllowanceBehavior,turn: TurnMethod = .sheetwise) -> Project {
        var p = Project(pages:(1...2).map { SourcePage(number:$0,trimSize:Size(210,297),availableBleed:0) },binding:.spiral,
            sheet:SheetSpec(size:Size(1000,1000)),settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0,safeAreaInset:0,turnMethod:turn),
            stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,allowRotation:false))
        p.blockAlignment = .center; p.leafSettings.allowance = 12; p.leafSettings.behavior = behavior; p.exportMarks = .none
        return p
    }
    func testA4TwelveMillimetresShrinkIsUniformAndAnchoredAwayFromBinding() throws {
        var p = project(.shrink); p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first),f = try XCTUnwrap(sheet.front.slots.first)
        XCTAssertEqual(f.bindingScale,198.0/210,accuracy:0.0000001)
        let r = BindingAllowanceLayout.transformed(Rect(x:f.x,y:f.y,width:210,height:297),slot:f)
        XCTAssertEqual(r.origin.x,f.x+12,accuracy:0.000001)
        XCTAssertEqual(r.origin.x+r.size.width,f.x+210,accuracy:0.000001)
        XCTAssertEqual(r.size.width/210,r.size.height/297,accuracy:0.000001)
        XCTAssertEqual(r.origin.y-f.y,(297-r.size.height)/2,accuracy:0.000001)
        XCTAssertTrue(f.bindingPlacementSummary.contains("94,29"))
        p.settings.safeAreaInset = 5
        let inset = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first?.front.slots.first)
        XCTAssertEqual(inset.bindingScale,188.0/210,accuracy:0.000001)
        XCTAssertEqual(inset.bindingTranslation.x,17,accuracy:0.000001)
    }
    func testBothBehaviorsMirrorOnPhysicalBackForEveryBindingEdgeTurnAndGripper() throws {
        for behavior in [BindingAllowanceBehavior.shrink,.shift] {
            for edge in [LeafBindingSettings.BindingEdge.left,.top,.right] {
                for turn in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
                    for gripper in [Edge.bottom,.left] {
                        var p = project(behavior,turn:turn); p.binding = .wireO
                        p.leafSettings.edge = edge; p.sheet.gripperEdge = gripper
                        let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
                        for (f,b) in zip(sheet.front.slots,sheet.back.slots) {
                            let a = BindingAllowanceLayout.transformed(Rect(x:f.x,y:f.y,width:f.size.width,height:f.size.height),slot:f)
                            let r = BindingAllowanceLayout.transformed(Rect(x:b.x,y:b.y,width:b.size.width,height:b.size.height),slot:b)
                            XCTAssertEqual(r.origin.x,sheet.backFlipsX ? sheet.size.width-a.origin.x-a.size.width : a.origin.x,accuracy:0.000001)
                            XCTAssertEqual(r.origin.y,sheet.backFlipsX ? a.origin.y : sheet.size.height-a.origin.y-a.size.height,accuracy:0.000001)
                            XCTAssertEqual(f.bindingScale,b.bindingScale)
                        }
                    }
                }
            }
        }
    }
    func testShiftKeepsFullPageOutsideTrimAndWarnsInsteadOfBlockingAtSheetEdge() throws {
        var p = project(.shift); p.sheet = SheetSpec(size:Size(210,297),orientation:.portrait)
        p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        let plan = ImpositionPlanner.plan(p),slot = try XCTUnwrap(plan.sheets.first?.front.slots.first),clip = try XCTUnwrap(slot.artworkClip)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertEqual(slot.bindingScale,1); XCTAssertEqual(slot.bindingTranslation,Point(12,0))
        XCTAssertEqual(clip.size,Size(210,297)); XCTAssertEqual(clip.origin.x,12,accuracy:0.000001)
        XCTAssertTrue(plan.issues.contains { $0.code == .bindingAllowance && $0.message.contains("tabaka sınırını aşıyor") })
        p = project(.shift)
        p.pages = (1...8).map { SourcePage(number:$0,trimSize:Size(210,297),availableBleed:0) }
        XCTAssertTrue(ImpositionPlanner.plan(p).issues.contains { $0.code == .bindingAllowance && $0.message.contains("komşu ürün") })
    }
    func testPreserveRetainsLegacyGeometryAndMissingBehaviorDecodesAsPreserve() throws {
        var p = project(.preserve); let original = ImpositionPlanner.plan(p)
        p.leafBinding?.placementBehavior = nil
        XCTAssertEqual(original.sheets,ImpositionPlanner.plan(p).sheets)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p.leafSettings)) as? [String:Any])
        json.removeValue(forKey:"placementBehavior")
        let restored = try JSONDecoder().decode(LeafBindingSettings.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(restored.behavior,.preserve)
    }
}
