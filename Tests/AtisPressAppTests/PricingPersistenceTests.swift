import XCTest
import ImpositionCore
@testable import AtisPressApp

@MainActor final class PricingPersistenceTests: XCTestCase {
    func testTablePersistenceImportExportAndFailedImportLeavesLibraryIntact() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("Prices/library.json"), export = dir.appendingPathComponent("export.json")
        let store = PricingStore(url:url)
        XCTAssertTrue(store.library.entries.isEmpty); XCTAssertNil(store.library.vat)
        var p = PriceEntry(name:"Kuşe"); p.price = Decimal(string:"123.45"); p.perThousand = true
        store.library.entries = [p]; store.library.vat = 20; store.save()
        XCTAssertNil(store.error)
        try store.exportFile(export)
        let next = PricingStore(url:dir.appendingPathComponent("Other/library.json")); try next.importFile(export)
        XCTAssertEqual(next.library,store.library)
        XCTAssertEqual(PricingStore(url:url).library,store.library)
        try Data("{\"version\":99}".utf8).write(to:export)
        XCTAssertThrowsError(try next.importFile(export)); XCTAssertEqual(next.library,store.library)
    }
    func testProjectSaveOpenPreservesOverridesQuoteAndLegacyDefaults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let model = Workspace()
        var entry = PriceEntry(name:"Özel kuşe"); entry.price = 5
        var settings = JobCostSettings(); settings.paper = PriceSelection(entry.id); settings.paper?.override = entry
        settings.margin = 15; settings.vat = 20; settings.extraWasteSheets = 12; settings.quote.company = "Atış"; settings.quote.validity = "15 gün"; settings.quote.logo = Data([1,2,3])
        model.project.costing = settings
        let url = dir.appendingPathComponent("job.atispress"); try model.saveProject(as:url)
        XCTAssertEqual(try ProjectDocument.decode(Data(contentsOf:url)).version,ProjectDocument.currentVersion)
        let restored = Workspace(); try await restored.loadProject(at:url)
        XCTAssertEqual(restored.project.costing,settings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]); json["version"] = 15
        var state = json["state"] as! [String:Any], project = state["project"] as! [String:Any]
        project.removeValue(forKey:"costing"); state["project"] = project; json["state"] = state
        let legacy = try ProjectDocument.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(legacy.state.project.costing)
    }
}
