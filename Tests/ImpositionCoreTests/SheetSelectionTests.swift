import XCTest
@testable import ImpositionCore

final class SheetSelectionTests: XCTestCase {
    private func project(_ size: Size,_ production: ProductionType = .digital) -> Project {
        var p = Project(pages: [SourcePage(number: 1,trimSize: size)],sheet: SheetSpec(preset: .sra3))
        p.autoLayout = AutoLayoutSettings(); p.autoLayout?.production = production
        return p
    }
    func testCardStaysOnProductionDefaultAndEfficiencyIsOptIn() {
        for (production,stock) in [(ProductionType.digital,SheetPreset.sra3),(.offset,.cm33x48)] {
            var p = project(Size(85,55),production)
            let automatic = SmartAutoLayout.arrange(p)
            XCTAssertEqual(automatic.project.sheet.size,stock.size)
            XCTAssertEqual(automatic.project.autoLayout?.level,.full)
            p.autoLayout?.sheetSelection = .efficient
            let efficient = SmartAutoLayout.arrange(p)
            XCTAssertEqual(efficient.project.sheet.size,SheetPreset.cm70x100.size)
            XCTAssertGreaterThan(efficient.plan.sheets[0].repeatLayout!.copiesPerSheet,automatic.plan.sheets[0].repeatLayout!.copiesPerSheet)
        }
    }
    func testStandardPaperWinsBeforeDefaultsAndLargeItemUsesSmallestFittingStock() {
        let a4 = SmartAutoLayout.arrange(project(Size(210,297)))
        XCTAssertEqual(a4.project.sheet.size,SheetPreset.a4.size)
        XCTAssertEqual(a4.plan.sheets.first?.repeatLayout?.copiesPerSheet,1)
        let large = SmartAutoLayout.arrange(project(Size(360,520)))
        XCTAssertEqual(large.project.sheet.size,SheetPreset.cm50x70.size)
        let custom = SmartAutoLayout.arrange(project(Size(850,1300)))
        XCTAssertEqual(custom.presetName,"Özel")
        XCTAssertTrue(custom.plan.canExport)
    }
    func testFixedStockRemainsFixedAndOlderMetadataKeepsItsPolicy() throws {
        var p = project(Size(85,55))
        p.sheet.size = SheetPreset.cm35x50.size
        p.autoLayout?.sheetSelection = .fixed
        XCTAssertEqual(SmartAutoLayout.arrange(p).project.sheet.size,SheetPreset.cm35x50.size)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p.autoLayout!)) as? [String:Any])
        object.removeValue(forKey: "selectionPolicy")
        let old = try JSONDecoder().decode(AutoLayoutSettings.self,from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.sheetSelection,.efficient)
    }
}
