import XCTest
@testable import ImpositionCore

final class UprightSheetPreferenceTests: XCTestCase {
    func test867x54On33x48PrefersUprightWhenBothOrientationsFit25() throws {
        var project = Project(pages:[SourcePage(number:1,trimSize:Size(86.7,54),availableBleed:3)],
            sheet:SheetSpec(preset:.cm33x48,margins:Insets(left:10,right:10,top:10,bottom:10),gripperWidth:10),
            settings:ImpositionSettings(bleed:3,cropMarkLength:3,cropMarkOffset:3))
        project.sheet.orientation = .portrait
        let portrait = try XCTUnwrap(ImpositionPlanner.plan(project).sheets.first)
        project.sheet.orientation = .landscape
        let landscape = try XCTUnwrap(ImpositionPlanner.plan(project).sheets.first)
        XCTAssertEqual(portrait.repeatLayout?.copiesPerSheet,25)
        XCTAssertEqual(landscape.repeatLayout?.copiesPerSheet,25)
        XCTAssertEqual(portrait.front.slots.first?.rotation,90)
        XCTAssertEqual(landscape.front.slots.first?.rotation,0)
        project.sheet.orientation = .auto
        let automatic = try XCTUnwrap(ImpositionPlanner.plan(project).sheets.first)
        XCTAssertEqual(automatic.repeatLayout?.copiesPerSheet,25)
        XCTAssertEqual(automatic.front.slots.first?.rotation,0)
        XCTAssertEqual(automatic.size,landscape.size)
    }
}
