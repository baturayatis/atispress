import XCTest
@testable import ImpositionCore

final class StepAndRepeatTests: XCTestCase {
    func project(_ count: Int = 2, method: TurnMethod = .sheetwise) -> Project {
        Project(pages: (1...count).map { SourcePage(number: $0,trimSize: Size(30,20),availableBleed: 3) },
            binding: .stepAndRepeat,sheet: SheetSpec(size: Size(100,80),orientation: .landscape),
            settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1,turnMethod: method),
            stepAndRepeat: StepAndRepeatSettings(allowRotation: false))
    }
    func testAutomaticGridAndSingleSidedNoPadding() throws {
        var p = project(1); p.blankPagePolicy = .reject
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.addedBlankPages,0)
        let sheet = try XCTUnwrap(plan.sheets.first), layout = try XCTUnwrap(sheet.repeatLayout)
        XCTAssertEqual(layout.columns,3); XCTAssertEqual(layout.rows,4)
        XCTAssertEqual(layout.copiesPerSheet,12)
        XCTAssertEqual(sheet.front.slots.map(\.sourcePageNumber),Array(repeating: 1,count: 12))
        XCTAssertTrue(sheet.back.slots.allSatisfy { $0.sourcePageNumber == nil })
        XCTAssertEqual(plan.totalPressSheets,1)
        XCTAssertFalse(plan.issues.contains { $0.code == .pageCountPadding })
    }
    func testConsecutivePairsAndQuantityDoNotDuplicateGeometry() throws {
        var p = project(5); p.pages = [p.pages[4],p.pages[1],p.pages[0],p.pages[3],p.pages[2]]
        p.stepAndRepeat.quantity = 37
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.sheets.count,3)
        XCTAssertEqual(plan.totalPressSheets,12); XCTAssertEqual(plan.addedBlankPages,0)
        XCTAssertEqual(plan.sheets.map { $0.repeatLayout?.frontPageNumber },[5,1,3])
        XCTAssertEqual(plan.sheets.map { $0.repeatLayout?.backPageNumber },[2,4,nil])
        for sheet in plan.sheets {
            XCTAssertEqual(sheet.repeatCount,4)
            XCTAssertEqual(sheet.front.slots.count,12)
            XCTAssertEqual(sheet.repeatLayout?.requestedQuantity,37)
            XCTAssertEqual(sheet.repeatCount * sheet.repeatLayout!.copiesPerSheet,48)
        }
        XCTAssertEqual(p.pages.count,5)
    }
    func testBackRowColumnIndexMappingForEveryWorkStyle() throws {
        for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            var p = project(method: method)
            p.sheet.margins = Insets(left: 3,right: 7,top: 4,bottom: 2)
            p.sheet.gripperWidth = 3
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport)
            let sheet = try XCTUnwrap(plan.sheets.first), layout = try XCTUnwrap(sheet.repeatLayout)
            XCTAssertEqual(sheet.front.slots.count,sheet.back.slots.count)
            for (front,back) in zip(sheet.front.slots,sheet.back.slots) {
                let f = try XCTUnwrap(front.gridPosition), b = try XCTUnwrap(back.gridPosition)
                XCTAssertEqual(front.copyIndex,back.copyIndex)
                if method == .workAndTumble {
                    XCTAssertEqual(b.column,f.column); XCTAssertEqual(b.row,layout.rows-1-f.row)
                    XCTAssertEqual(back.y,sheet.size.height-front.y-front.size.height,accuracy: 0.00001)
                    XCTAssertEqual(back.x,front.x)
                } else {
                    XCTAssertEqual(b.row,f.row); XCTAssertEqual(b.column,layout.columns-1-f.column)
                    XCTAssertEqual(back.x,sheet.size.width-front.x-front.size.width,accuracy: 0.00001)
                    XCTAssertEqual(back.y,front.y)
                }
                XCTAssertEqual(Set([front.sourcePageNumber,back.sourcePageNumber]),[1,2])
                XCTAssertFalse(front.mirrored); XCTAssertFalse(back.mirrored) // Reflect placement, not printed glyphs.
            }
            if method == .workAndTurn { XCTAssertEqual(layout.columns%2,0) }
            if method == .workAndTumble { XCTAssertEqual(layout.rows%2,0) }
            if method != .sheetwise {
                // The same plate must describe both faces, after mapping physical cut-piece indices.
                for front in sheet.front.slots {
                    let back = try XCTUnwrap(sheet.back.slots.first { $0.gridPosition == front.gridPosition })
                    XCTAssertEqual(front.sourcePageNumber,back.sourcePageNumber)
                    XCTAssertEqual(front.rotation,back.rotation)
                    XCTAssertEqual(front.origin,back.origin)
                }
            }
        }
    }
    func testRotationAndOrientationMaximizeCapacity() throws {
        var p = project()
        p.pages = [SourcePage(number: 1,trimSize: Size(40,30))]
        p.sheet = SheetSpec(size: Size(70,100),orientation: .portrait)
        p.stepAndRepeat.allowRotation = true
        let rotated = ImpositionPlanner.plan(p)
        XCTAssertEqual(rotated.sheets[0].repeatLayout?.copiesPerSheet,4)
        XCTAssertEqual(rotated.sheets[0].front.slots[0].rotation,90)
        p.stepAndRepeat.allowRotation = false
        XCTAssertEqual(ImpositionPlanner.plan(p).sheets[0].repeatLayout?.copiesPerSheet,3)
        p.sheet.orientation = .auto
        let automatic = ImpositionPlanner.plan(p)
        XCTAssertEqual(automatic.sheets[0].size,Size(100,70))
        XCTAssertEqual(automatic.sheets[0].repeatLayout?.copiesPerSheet,4)
        XCTAssertEqual(automatic.sheets[0].front.slots[0].rotation,0)
    }
    func testRotatedItemBacksKeepCorrectHeadDirection() throws {
        for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
            var p = project(method: method)
            p.pages = [1,2].map { SourcePage(number: $0,trimSize: Size(40,30)) }
            p.sheet = SheetSpec(size: Size(70,100),orientation: .portrait)
            p.stepAndRepeat.allowRotation = true
            let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
            XCTAssertEqual(sheet.front.slots[0].rotation,90)
            XCTAssertEqual(sheet.back.slots[0].rotation,method == .workAndTumble ? 90 : 270)
        }
    }
    func testBleedGutterMarginsGripperAndManualOverrides() throws {
        var p = project()
        p.settings.bleed = 3; p.sheet.gutter = 2
        let spaced = ImpositionPlanner.plan(p)
        XCTAssertEqual(spaced.sheets[0].repeatLayout?.copiesPerSheet,4)
        XCTAssertEqual(spaced.sheets[0].front.slots[1].x-spaced.sheets[0].front.slots[0].x,38,accuracy: 0.001)
        p.sheet.gutter = 0
        let shared = ImpositionPlanner.plan(p)
        XCTAssertEqual(shared.sheets[0].repeatLayout?.copiesPerSheet,9)
        XCTAssertTrue(shared.issues.contains { $0.code == .sharedCutBleed })
        p = project(); p.sheet.margins = Insets(left: 10,right: 10,top: 10,bottom: 10)
        p.sheet.gripperWidth = 5
        let reserved = ImpositionPlanner.plan(p)
        XCTAssertEqual(reserved.sheets[0].repeatLayout?.copiesPerSheet,4)
        XCTAssertGreaterThanOrEqual(reserved.sheets[0].front.slots[0].y,15)
        p = project(); p.stepAndRepeat.columns = 2
        XCTAssertEqual(ImpositionPlanner.plan(p).sheets[0].repeatLayout?.copiesPerSheet,8)
        p.stepAndRepeat.rows = 2; p.stepAndRepeat.quantity = 9
        let manual = ImpositionPlanner.plan(p)
        XCTAssertEqual(manual.sheets[0].repeatLayout?.copiesPerSheet,4)
        XCTAssertEqual(manual.totalPressSheets,3)
        p.stepAndRepeat.columns = 5
        XCTAssertTrue(ImpositionPlanner.plan(p).issues.contains { $0.code == .exceedsSheet })
    }
    func testSharedCropCutsAreUniqueAndNeverCrossArtwork() throws {
        var p = project()
        p.sheet = SheetSpec(size: Size(130,100),orientation: .landscape)
        p.settings.cropMarkLength = 3; p.settings.cropMarkOffset = 2; p.settings.bleed = 2
        p.stepAndRepeat.columns = 3; p.stepAndRepeat.rows = 2
        let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
        let crops = sheet.front.marks.filter { $0.kind == .crop }
        XCTAssertEqual(crops.count,2*((3+1)+(2+1)))
        for mark in crops {
            for slot in sheet.front.slots {
                // Each tick lies outside at least one axis of every trim rectangle.
                let outsideX = max(mark.start.x,mark.end.x) <= slot.x || min(mark.start.x,mark.end.x) >= slot.x+slot.size.width
                let outsideY = max(mark.start.y,mark.end.y) <= slot.y || min(mark.start.y,mark.end.y) >= slot.y+slot.size.height
                XCTAssertTrue(outsideX || outsideY)
            }
        }
        for kind in [MarkKind.bleed,.safeArea,.pageLabel,.margin,.gripper] {
            XCTAssertTrue(sheet.front.marks.contains { $0.kind == kind })
        }
        XCTAssertFalse(sheet.front.marks.contains { $0.kind == .fold })
        p.sheet.gutter = 4
        XCTAssertEqual(ImpositionPlanner.plan(p).sheets[0].front.marks.filter { $0.kind == .crop }.count,48)
    }
    func testDifferentJobsMayHaveDifferentSizesButEachPairMustMatch() {
        var p = project(4)
        p.pages[2].trimSize = Size(15,10); p.pages[3].trimSize = Size(15,10)
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport)
        XCTAssertEqual(plan.sheets.map { $0.repeatLayout?.copiesPerSheet },[12,48])
        p.pages[3].trimSize = Size(16,10)
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        XCTAssertTrue(ImpositionPlanner.plan(p).issues.contains { $0.code == .mixedPageSizes })
    }
    func testInvalidOverridesQuantitiesAndNoFitAreReported() {
        var p = project(method: .workAndTurn); p.stepAndRepeat.columns = 3
        XCTAssertEqual(ImpositionPlanner.plan(p).issues.first?.code,.invalidInput)
        p = project(method: .workAndTumble); p.stepAndRepeat.rows = 3
        XCTAssertEqual(ImpositionPlanner.plan(p).issues.first?.code,.invalidInput)
        for value in [0,-1] {
            p = project(); p.stepAndRepeat.quantity = value
            XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        }
        p = project(); p.stepAndRepeat.quantity = Int.max
        XCTAssertTrue(ImpositionPlanner.plan(p).canExport)
        p = project(); p.sheet.size = Size(1,1)
        XCTAssertEqual(ImpositionPlanner.plan(p).issues.first?.code,.exceedsSheet)
        p = project(); p.sheet.gutter = .nan
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
    }
    func testAllGripperEdgesDetermineThePhysicalTurnAxis() throws {
        for edge in [Edge.bottom,.top,.left,.right] {
            for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
                var p = project(1,method: method)
                p.sheet.gripperEdge = edge; p.sheet.gripperWidth = 3
                let sheet = try XCTUnwrap(ImpositionPlanner.plan(p).sheets.first)
                let layout = try XCTUnwrap(sheet.repeatLayout)
                let mirrorX = (edge == .left || edge == .right) == (method == .workAndTumble)
                for (front,back) in zip(sheet.front.slots,sheet.back.slots) {
                    let f = try XCTUnwrap(front.gridPosition), b = try XCTUnwrap(back.gridPosition)
                    XCTAssertEqual(b.column,mirrorX ? layout.columns-1-f.column : f.column)
                    XCTAssertEqual(b.row,mirrorX ? f.row : layout.rows-1-f.row)
                    XCTAssertEqual(Set([front.sourcePageNumber,back.sourcePageNumber]),[1,nil])
                }
                if method != .sheetwise { XCTAssertEqual((mirrorX ? layout.columns : layout.rows)%2,0) }
            }
        }
    }

}
