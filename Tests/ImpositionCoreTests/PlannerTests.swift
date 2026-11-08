import XCTest
@testable import ImpositionCore

final class PlannerTests: XCTestCase {
    func project(_ count: Int, binding: BindingMethod = .saddleStitch,
                 size: Size = Size(200, 140), page: Size = Size(100, 140),
                 signature: SignatureSize = .sixteen, turn: TurnMethod = .sheetwise) -> Project {
        Project(pages: (1...count).map { SourcePage(number: $0, trimSize: page, availableBleed: 0) },
                binding: binding, sheet: SheetSpec(size: size),
                settings: ImpositionSettings(bleed: 0, cropMarkLength: 0, cropMarkOffset: 0,
                                             signatureSize: signature, turnMethod: turn))
    }
    func numbers(_ side: Side) -> [Int?] { side.slots.map(\.sourcePageNumber) }
    func testSaddleEight() {
        let p = ImpositionPlanner.plan(project(8))
        XCTAssertTrue(p.canExport); XCTAssertEqual(p.sheets.count, 2)
        XCTAssertEqual(numbers(p.sheets[0].front), [8,1]); XCTAssertEqual(numbers(p.sheets[0].back), [2,7])
        XCTAssertEqual(numbers(p.sheets[1].front), [6,3]); XCTAssertEqual(numbers(p.sheets[1].back), [4,5])
    }
    func testSaddleTwelveAndTen() {
        let p = ImpositionPlanner.plan(project(12))
        XCTAssertEqual(p.sheets.map { numbers($0.front) }, [[12,1],[10,3],[8,5]])
        XCTAssertEqual(p.sheets.map { numbers($0.back) }, [[2,11],[4,9],[6,7]])
        let q = ImpositionPlanner.plan(project(10))
        XCTAssertTrue(q.canExport); XCTAssertEqual(q.addedBlankPages,2)
        XCTAssertEqual(q.sheets.map { numbers($0.front) }, [[nil,1],[10,3],[8,5]])
        XCTAssertEqual(q.sheets.map { numbers($0.back) }, [[2,nil],[4,9],[6,7]])
    }
    /// A paper panel has two printed faces. Moving paper flips its faces, reverses
    /// stack order and, for a horizontal crease, turns text through 180 degrees.
    /// This simulator uses the output geometry, never the planner's page-pair formula.
    struct Paper {
        var top: Int?
        var bottom: Int?
        var topRotation: Int
        var bottomRotation: Int
        func flipped(horizontalCrease: Bool) -> Paper {
            let r = horizontalCrease ? 180 : 0
            return Paper(top: bottom, bottom: top, topRotation: (bottomRotation+r)%360,
                         bottomRotation: (topRotation+r)%360)
        }
    }
    func foldAndRead(_ sheet: Sheet, columns: Int, rows: Int, page: Size) -> ([Int?], [Int]) {
        var panels: [[[Paper]]] = []
        for y in 0..<rows {
            var row: [[Paper]] = []
            for x in 0..<columns {
                let f = sheet.front.slots.first { abs($0.x-Double(x)*page.width)<0.001 && abs($0.y-Double(y)*page.height)<0.001 }!
                let b = sheet.back.slots.first { abs($0.x-Double(columns-1-x)*page.width)<0.001 && abs($0.y-Double(y)*page.height)<0.001 }!
                row.append([Paper(top: f.sourcePageNumber, bottom: b.sourcePageNumber, topRotation: f.rotation, bottomRotation: b.rotation)])
            }
            panels.append(row)
        }
        while panels[0].count > 1 {
            panels = panels.map { row in
                let half = row.count/2
                return (0..<half).map { i in row[half-1-i].reversed().map { $0.flipped(horizontalCrease: false) } + row[half+i] }
            }
        }
        while panels.count > 1 {
            let half = panels.count/2
            panels = (0..<half).map { i in
                [panels[half-1-i][0].reversed().map { $0.flipped(horizontalCrease: true) } + panels[half+i][0]]
            }
        }
        return (panels[0][0].flatMap { [$0.top,$0.bottom] }, panels[0][0].flatMap { [$0.topRotation,$0.bottomRotation] })
    }
    func testPhysicalFoldSimulation() {
        for (n, signature, columns, rows) in [(8,SignatureSize.eight,2,2),(16,.sixteen,4,2),(32,.thirtyTwo,4,4)] {
            let page = Size(40,60)
            let plan = ImpositionPlanner.plan(project(n, binding: .perfectBound,
                size: Size(Double(columns)*40,Double(rows)*60), page: page, signature: signature))
            XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.sheets.count,1)
            let (pages, rotations) = foldAndRead(plan.sheets[0], columns: columns, rows: rows, page: page)
            XCTAssertEqual(pages, (1...n).map(Optional.init))
            XCTAssertTrue(rotations.allSatisfy { $0 == 0 })
        }
    }
    func testBlankCounts106() {
        XCTAssertEqual(ImpositionPlanner.plan(project(106)).addedBlankPages,2)
        for signature in [SignatureSize.eight,.sixteen,.thirtyTwo] {
            let plan = ImpositionPlanner.plan(project(106,binding: .perfectBound,size: Size(1000,1000),signature: signature))
            XCTAssertTrue(plan.canExport)
            XCTAssertEqual(plan.addedBlankPages,signature == .thirtyTwo ? 22 : 6)
            let pages = plan.sheets.flatMap { $0.front.slots + $0.back.slots }.compactMap(\.sourcePageNumber)
            XCTAssertEqual(pages.sorted(),Array(1...106))
        }
        let auto = ImpositionPlanner.plan(project(106,binding: .perfectBound,size: Size(1000,1000),signature: .automatic))
        XCTAssertTrue(auto.canExport)
        XCTAssertEqual(auto.signaturePageCount,4)
        XCTAssertEqual(auto.addedBlankPages,2)
    }
    func testPackingAndOrientation() {
        var p = project(12,size: Size(210,150),page: Size(50,70))
        let auto = ImpositionPlanner.plan(p)
        XCTAssertEqual(auto.sheets.count,1)
        XCTAssertEqual(auto.sheets.first?.size,Size(210,150))
        p.sheet.orientation = .portrait
        let portrait = ImpositionPlanner.plan(p)
        XCTAssertEqual(portrait.sheets.count,1)
        XCTAssertEqual(portrait.sheets[0].front.slots[0].rotation,90)
        p.sheet.orientation = .landscape
        XCTAssertEqual(ImpositionPlanner.plan(p).sheets.count,1)
        p.sheet.size = Size(40,40)
        let bad = ImpositionPlanner.plan(p)
        XCTAssertFalse(bad.canExport); XCTAssertTrue(bad.issues.contains { $0.code == .exceedsSheet })
    }
    func testBackReflectionAndSharedPlate() {
        for method in [TurnMethod.workAndTurn,.workAndTumble] {
            let size = method == .workAndTurn ? Size(400,140) : Size(200,280)
            var p = project(4,size: size,turn: method)
            p.sheet.orientation = size.width > size.height ? .landscape : .portrait
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.sheets.count,1)
            let sheet = plan.sheets[0]
            XCTAssertEqual(sheet.front.slots.count,4)
            XCTAssertEqual(numbers(sheet.front).compactMap{$0}.sorted(),[1,2,3,4])
            for (f,b) in zip(sheet.front.slots,sheet.back.slots) {
                XCTAssertEqual(f.sourcePageNumber,b.sourcePageNumber)
                XCTAssertNotEqual(f.mirrored,b.mirrored)
                if method == .workAndTurn {
                    XCTAssertEqual(b.x,sheet.size.width-f.x-f.size.width,accuracy: 0.001)
                    XCTAssertEqual(b.y,f.y)
                    XCTAssertEqual(b.rotation,(360-f.rotation)%360)
                } else {
                    XCTAssertEqual(b.y,sheet.size.height-f.y-f.size.height,accuracy: 0.001)
                    XCTAssertEqual(b.x,f.x)
                    XCTAssertEqual(b.rotation,(540-f.rotation)%360)
                }
            }
            // Each cut half contains the two corresponding faces, viewed with the sheet turn.
            let frontNormal = sheet.front.slots.filter { !$0.mirrored }.compactMap(\.sourcePageNumber)
            let backNormal = sheet.back.slots.filter { !$0.mirrored }.compactMap(\.sourcePageNumber)
            XCTAssertEqual(frontNormal,[4,1]); XCTAssertEqual(backNormal,[2,3])
        }
    }
    func testValidationAndSelection() {
        var p = project(4)
        for binding in [BindingMethod.spiral,.wireO] {
            p.binding = binding
            let plan = ImpositionPlanner.plan(p)
            XCTAssertFalse(plan.canExport); XCTAssertEqual(plan.issues.first?.code,.unsupportedBinding)
        }
        p.binding = .saddleStitch
        p.pages[0].trimSize.width = 99
        XCTAssertEqual(ImpositionPlanner.plan(p).issues.first?.code,.mixedPageSizes)
        p = project(10); p.blankPagePolicy = .reject
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p = project(4); p.pages.reverse()
        XCTAssertEqual(numbers(ImpositionPlanner.plan(p).sheets[0].front),[1,4])
        p.coverMode = .separate
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p = project(4); p.pages = []
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
        p = project(4); p.sheet.gutter = .nan
        XCTAssertFalse(ImpositionPlanner.plan(p).canExport)
    }
    func testMarksMarginsAndGripper() {
        var p = project(4,size: Size(260,200))
        p.settings = ImpositionSettings(bleed: 3,cropMarkLength: 5,cropMarkOffset: 3)
        p.sheet.margins = Insets(left: 5,right: 5,top: 5,bottom: 5)
        p.sheet.gripperWidth = 10
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport)
        XCTAssertTrue(plan.issues.contains { $0.code == .missingBleed })
        let f = plan.sheets[0].front
        XCTAssertEqual(f.slots[0].origin,Point(13,23))
        for kind in [MarkKind.crop,.fold,.bleed,.safeArea,.pageLabel] {
            XCTAssertTrue(f.marks.contains { $0.kind == kind })
        }
        XCTAssertTrue(f.marks.contains { $0.kind == .crop && $0.start == Point(10,23) && $0.end == Point(5,23) })
        XCTAssertTrue(f.marks.contains { $0.kind == .bleed && $0.start == Point(10,20) })
        for mark in f.marks where mark.kind != .margin && mark.kind != .gripper {
            for point in [mark.start,mark.end] {
                XCTAssertGreaterThanOrEqual(point.x,5); XCTAssertGreaterThanOrEqual(point.y,15)
                XCTAssertLessThanOrEqual(point.x,255); XCTAssertLessThanOrEqual(point.y,195)
            }
        }
    }
    func testAutomaticChoosesFittingSignatureAndMultipleSignatures() {
        let plan = ImpositionPlanner.plan(project(24,binding: .perfectBound,size: Size(200,280),signature: .automatic))
        XCTAssertTrue(plan.canExport); XCTAssertEqual(plan.signaturePageCount,8)
        XCTAssertEqual(plan.addedBlankPages,0); XCTAssertEqual(plan.sheets.count,3)
        let packed = ImpositionPlanner.plan(project(32,binding: .perfectBound,size: Size(800,280),signature: .sixteen))
        XCTAssertTrue(packed.canExport); XCTAssertEqual(packed.sheets.count,1)
        XCTAssertEqual(Set(packed.sheets[0].front.slots.map(\.signature)),[0,1])
    }
    func testLargeJobsAndExactPageConservation() {
        for binding in [BindingMethod.saddleStitch,.perfectBound] {
            let plan = ImpositionPlanner.plan(project(1001,binding: binding,size: Size(1000,1400)))
            XCTAssertTrue(plan.canExport)
            let slots = plan.sheets.flatMap { $0.front.slots + $0.back.slots }
            XCTAssertEqual(slots.compactMap(\.sourcePageNumber).sorted(),Array(1...1001))
            XCTAssertEqual(slots.filter { $0.sourcePageNumber == nil }.count,plan.addedBlankPages)
            for sheet in plan.sheets {
                for side in [sheet.front,sheet.back] {
                    for slot in side.slots {
                        XCTAssertGreaterThanOrEqual(slot.x,0); XCTAssertGreaterThanOrEqual(slot.y,0)
                        XCTAssertLessThanOrEqual(slot.x+slot.size.width,sheet.size.width)
                        XCTAssertLessThanOrEqual(slot.y+slot.size.height,sheet.size.height)
                    }
                }
            }
        }
    }
    func testTurnStylesRespectAsymmetricMarginsAndMarks() {
        for method in [TurnMethod.workAndTurn,.workAndTumble] {
            var p = project(8,size: Size(600,600),page: Size(40,60),turn: method)
            p.sheet.margins = Insets(left: 7,right: 19,top: 23,bottom: 11)
            p.sheet.gripperWidth = 12
            p.sheet.gutter = 20
            p.settings.bleed = 3; p.settings.cropMarkOffset = 4; p.settings.cropMarkLength = 5
            let plan = ImpositionPlanner.plan(p)
            XCTAssertTrue(plan.canExport)
            for sheet in plan.sheets {
                for side in [sheet.front,sheet.back] {
                    for mark in side.marks where mark.kind != .margin && mark.kind != .gripper {
                        for point in [mark.start,mark.end] {
                            XCTAssertGreaterThanOrEqual(point.x,7); XCTAssertLessThanOrEqual(point.x,581)
                            XCTAssertGreaterThanOrEqual(point.y,23); XCTAssertLessThanOrEqual(point.y,577)
                        }
                    }
                }
            }
        }
    }

    func testPressGuidesAndBleedReferencesArePlanGeometry() {
        var p = project(4,size: Size(260,200))
        p.sheet.margins = Insets(left: 7,right: 11,top: 13,bottom: 17)
        p.sheet.gripperWidth = 8
        p.settings.bleed = 3
        let plan = ImpositionPlanner.plan(p)
        let marks = plan.sheets[0].front.marks
        XCTAssertEqual(marks.filter { $0.kind == .margin }.count,4)
        XCTAssertTrue(marks.contains { $0.kind == .margin && $0.start == Point(7,17) })
        XCTAssertTrue(marks.contains { $0.kind == .gripper && $0.start == Point(7,25) })
        let references = plan.issues.filter { $0.code == .missingBleed }.compactMap(\.slot)
        XCTAssertEqual(references.count,4)
        for reference in references {
            let sheet = plan.sheets[reference.sheet]
            let side = reference.side == .front ? sheet.front : sheet.back
            XCTAssertNotNil(side.slots[reference.slot].sourcePageNumber)
        }
    }

}
