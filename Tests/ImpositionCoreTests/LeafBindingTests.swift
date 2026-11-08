import XCTest
@testable import ImpositionCore

final class LeafBindingTests: XCTestCase {
    private func project(_ count: Int = 18,_ turn: TurnMethod = .sheetwise) -> Project {
        var p = Project(pages:(1...count).map { SourcePage(number:$0,trimSize:Size(40,60),availableBleed:3) },binding:.spiral,
            sheet:SheetSpec(size:Size(150,160),margins:Insets(left:15,right:15,top:15,bottom:15),orientation:.landscape),
            settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0,safeAreaInset:2,turnMethod:turn),
            stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,allowRotation:false))
        p.blockAlignment = .center; p.leafSettings.allowance = 5; p.exportMarks = .none
        return p
    }
    func testCutIntoGridPilesThenStackReadsEveryPageInOrderForBothBindings() throws {
        for binding in [BindingMethod.spiral,.wireO] {
            for turn in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
                var p = project(18,turn); p.binding = binding
                let plan = ImpositionPlanner.plan(p)
                XCTAssertTrue(plan.canExport,"\(plan.issues)")
                XCTAssertEqual(plan.addedBlankPages,0); XCTAssertEqual(plan.signatureCount,0)
                let first = try XCTUnwrap(plan.sheets.first)
                let copies = first.front.slots.filter { $0.itemSide == .front }.compactMap(\.copyIndex).sorted()
                // Physical simulation: cut equal grid positions into piles, stack
                // each pile in press-sheet order, then concatenate those piles.
                var read: [Int] = []
                for copy in copies {
                    for sheet in plan.sheets {
                        let f = try XCTUnwrap(sheet.front.slots.first { $0.copyIndex==copy })
                        let b = try XCTUnwrap(sheet.back.slots.first { $0.copyIndex==copy })
                        read += [f.sourcePageNumber,b.sourcePageNumber].compactMap { $0 }
                        XCTAssertEqual(b.x,sheet.backFlipsX ? sheet.size.width-f.x-f.size.width : f.x,accuracy:0.00001)
                        XCTAssertEqual(b.y,sheet.backFlipsX ? f.y : sheet.size.height-f.y-f.size.height,accuracy:0.00001)
                    }
                }
                XCTAssertEqual(read,Array(1...18))
                if turn != .sheetwise {
                    for sheet in plan.sheets { for f in sheet.front.slots {
                        let b = try XCTUnwrap(sheet.back.slots.first { abs($0.x-f.x)<0.00001 && abs($0.y-f.y)<0.00001 })
                        XCTAssertEqual(f.sourcePageNumber,b.sourcePageNumber,"Same plate must carry the same page at the same press position")
                    } }
                }
                XCTAssertFalse(plan.sheets.flatMap { $0.front.marks+$0.back.marks }.contains { $0.kind == .fold })
            }
        }
    }
    func testOddPageNeedsOnlyOneBlankAndRejectPolicyStillBlocks() {
        var p = project(7)
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.addedBlankPages,1)
        XCTAssertEqual(plan.readingOrder,[1,2,3,4,5,6,7,nil]); XCTAssertEqual(plan.blankPositions,[8])
        p.blankPagePolicy = .reject; XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
    }
    func testBindingEdgesAndAllowanceMirrorOnEveryPhysicalBackAndNeverScaleArtwork() throws {
        for edge in [LeafBindingSettings.BindingEdge.left,.top,.right] {
            for turn in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
                for gripper in [Edge.bottom,.left] {
                    var p = project(8,turn); p.leafSettings.edge = edge; p.sheet.gripperEdge = gripper
                    let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first)
                    for (f,b) in zip(sheet.front.slots,sheet.back.slots) {
                        XCTAssertEqual(b.bindingEdge,LeafPlanner.reflectedEdge(try XCTUnwrap(f.bindingEdge),mirrorX:sheet.backFlipsX))
                        XCTAssertEqual(f.size,Size(40,60)); XCTAssertEqual(f.artworkOffset,Point(0,0))
                        let safe = LeafPlanner.safeRect(f,inset:2)
                        XCTAssertEqual(safe.size.width,f.size.width-4-((f.bindingEdge == .left || f.bindingEdge == .right) ? 5 : 0))
                        XCTAssertEqual(safe.size.height,f.size.height-4-((f.bindingEdge == .top || f.bindingEdge == .bottom) ? 5 : 0))
                    }
                }
            }
        }
    }
    func testHolePitchDiameterOffsetAreExactAndNoRoomSkipsWithoutArtworkOverlap() throws {
        var p = project(2); p.stepAndRepeat.columns = 1; p.stepAndRepeat.rows = 1
        p.leafSettings.holes = true; p.leafSettings.pitch = 12; p.leafSettings.diameter = 3; p.leafSettings.offset = 6
        let plan = ImpositionPlanner.plan(p),sheet = try XCTUnwrap(plan.sheets.first),f = try XCTUnwrap(sheet.front.slots.first)
        XCTAssertEqual(sheet.front.punchMarks.count,5)
        XCTAssertEqual(sheet.front.punchMarks.first?.center,Point(f.x-6,f.y+6))
        for (a,b) in zip(sheet.front.punchMarks,sheet.front.punchMarks.dropFirst()) { XCTAssertEqual(b.center.y-a.center.y,12,accuracy:0.00001); XCTAssertEqual(a.diameter,3) }
        let back = sheet.back.punchMarks
        for mark in sheet.front.punchMarks { XCTAssertTrue(back.contains { abs($0.center.x-(sheet.size.width-mark.center.x))<0.00001 && abs($0.center.y-mark.center.y)<0.00001 }) }
        p.leafSettings.offset = 1000
        let noRoom = ImpositionPlanner.plan(p)
        XCTAssertTrue(noRoom.sheets.allSatisfy { $0.front.punchMarks.isEmpty && $0.back.punchMarks.isEmpty })
        XCTAssertTrue(noRoom.issues.contains { $0.message.contains("yeterli boş kenar yok") })
        p.leafSettings.pitch = 1e-300; p.leafSettings.diameter = 1e-301
        XCTAssertTrue(ImpositionPlanner.plan(p).canExport,"Unusable punch geometry must warn, never overflow or block the leaf plan")
    }
    func testCoversAreIndependentLeavesAndMissingAllowanceWarns() throws {
        var p = project(8); p.coverMode = .excluded; p.leafBinding = nil
        var book = BookSettings(); book.selection.front = 1; book.selection.back = 8; book.creepEnabled = true
        p.book = book
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport,"\(plan.issues)")
        XCTAssertEqual(plan.addedBlankPages,0)
        XCTAssertEqual(plan.readingOrder,[2,3,4,5,6,7])
        XCTAssertEqual(plan.sheets.filter { $0.leafInfo?.cover == true }.count,2)
        XCTAssertTrue(plan.issues.contains { $0.message.contains("Cilt payı girilmedi") })
        XCTAssertTrue(plan.sheets.allSatisfy { $0.bookInfo == nil })
    }
}
