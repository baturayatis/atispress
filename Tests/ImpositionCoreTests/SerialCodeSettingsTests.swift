import XCTest
import ImpositionCore

final class SerialCodeSettingsTests: XCTestCase {
    func testPlaceholderIncludesFormattedPrefixDigitsAndSuffixAndStaticContentIgnoresCounter() throws {
        var field = SerialField(start: 7,digits: 5,prefix: "K-",suffix: "-X")
        field.kind = .qr
        field.codeSettings.template = "https://site.com/k/{no}?copy={no}"
        XCTAssertEqual(field.content(at: 0),"https://site.com/k/K-00007-X?copy=K-00007-X")
        XCTAssertEqual(field.codeSettings.quietZone,4); XCTAssertEqual(field.codeSettings.correction,.m)
        field.kind = .code128
        XCTAssertEqual(field.codeSettings.quietZone,10)
        field.codeSettings.template = "STATIC"
        field.start = Int64.max; field.step = 1
        XCTAssertFalse(field.usesSerialNumber)
        XCTAssertEqual(field.content(at: 99_999),"STATIC")
        var p = Project(pages: [SourcePage(number: 1,trimSize: Size(85,55))],sheet: SheetSpec(size: Size(220,160)),
            settings: ImpositionSettings(bleed: 0,cropMarkLength: 0,cropMarkOffset: 0,safeAreaInset: 1),
            stepAndRepeat: StepAndRepeatSettings(columns: 2,rows: 2,allowRotation: false,quantity: 100_000))
        p.serialFields = [field]
        let plan = ImpositionPlanner.plan(p)
        XCTAssertTrue(plan.canExport)
        let sheet = try XCTUnwrap(plan.sheets.first),recipe = try XCTUnwrap(sheet.serialPlan)
        XCTAssertEqual(recipe.placements(side: sheet.front,kind: .front,repetition: 24_999).map(\.content),Array(repeating: "STATIC",count: 4))
    }
    func testOldFieldsDecodeAsTextAndCodeSettingsRoundtrip() throws {
        let original = SerialField(start: 10,prefix: "OLD-")
        let old = try JSONDecoder().decode(SerialField.self,from: JSONEncoder().encode(original))
        XCTAssertNil(old.code); XCTAssertEqual(old.kind,.text); XCTAssertEqual(old.content(at: 2),"OLD-0012")
        var field = original; field.kind = .qr
        field.codeSettings.template = "{no}"; field.codeSettings.width = 32
        field.codeSettings.height = 17; field.codeSettings.correction = .h
        field.codeSettings.quietZone = 6; field.codeSettings.humanReadable = true; field.codeSettings.humanFontSize = 9
        field.rotation = 90; field.color = .cmyk(0.1,0.2,0,0.8)
        XCTAssertEqual(try JSONDecoder().decode(SerialField.self,from: JSONEncoder().encode(field)),field)
        var rgb = SerialField(color: .rgb(1,0,0)); rgb.kind = .code128
        XCTAssertEqual(rgb.color,.cmyk(0,0,0,1)); XCTAssertEqual(rgb.codeSettings.width,50)
    }
}
