import XCTest
import ImpositionCore

final class ArtworkClipTests: XCTestCase {
    func testPlanClipsKeepBleedWithoutCrossingAdjacentArtwork() throws {
        for binding in [BindingMethod.saddleStitch,.perfectBound,.stepAndRepeat] {
            for method in [TurnMethod.sheetwise,.workAndTurn,.workAndTumble] {
                for gutter in [0.0,2,10] {
                    let count = binding == .stepAndRepeat ? 2 : 32
                    let project = Project(pages: (1...count).map { SourcePage(number: $0,trimSize: Size(85,55),availableBleed: 3) },
                        binding: binding,sheet: SheetSpec(preset: .cm70x100,gutter: gutter),
                        settings: ImpositionSettings(signatureSize: .thirtyTwo,turnMethod: method))
                    let plan = ImpositionPlanner.plan(project)
                    XCTAssertTrue(plan.canExport)
                    for sheet in plan.sheets {
                        for side in [sheet.front,sheet.back] {
                            for (index,slot) in side.slots.enumerated() {
                                let clip = try XCTUnwrap(slot.artworkClip)
                                XCTAssertLessThanOrEqual(clip.origin.x,slot.x+0.000001)
                                XCTAssertLessThanOrEqual(clip.origin.y,slot.y+0.000001)
                                XCTAssertGreaterThanOrEqual(clip.origin.x+clip.size.width,slot.x+slot.size.width-0.000001)
                                XCTAssertGreaterThanOrEqual(clip.origin.y+clip.size.height,slot.y+slot.size.height-0.000001)
                                XCTAssertGreaterThanOrEqual(clip.origin.x,-0.000001)
                                XCTAssertGreaterThanOrEqual(clip.origin.y,-0.000001)
                                XCTAssertLessThanOrEqual(clip.origin.x+clip.size.width,sheet.size.width+0.000001)
                                XCTAssertLessThanOrEqual(clip.origin.y+clip.size.height,sheet.size.height+0.000001)
                                for other in side.slots.dropFirst(index+1) {
                                    let b = try XCTUnwrap(other.artworkClip)
                                    let width = min(clip.origin.x+clip.size.width,b.origin.x+b.size.width)-max(clip.origin.x,b.origin.x)
                                    let height = min(clip.origin.y+clip.size.height,b.origin.y+b.size.height)-max(clip.origin.y,b.origin.y)
                                    XCTAssertTrue(width <= 0.000001 || height <= 0.000001,"Adjacent bleed clips overlap")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
