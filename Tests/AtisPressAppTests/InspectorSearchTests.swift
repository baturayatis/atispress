import AppKit
import SwiftUI
import XCTest
import ImpositionCore
@testable import AtisPressApp

@MainActor
final class InspectorSearchTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let name = "InspectorSearchTests." + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    func testSearchRanksTurkishLabelsAndFindsKeywordsAcrossPanels() {
        XCTAssertEqual(InspectorSearchEntry.matches("  MAŞA PAYI ").first?.id, "gripperWidth")
        XCTAssertEqual(InspectorSearchEntry.matches("masa payi").first?.id, "gripperWidth")
        XCTAssertEqual(InspectorSearchEntry.matches("gÜvEnLİ alan").first?.id, "printSafe")
        XCTAssertTrue(InspectorSearchEntry.matches("onizleme katman renk").contains { $0.id == "previewColor" })
        XCTAssertTrue(InspectorSearchEntry.matches("kayıt baskı register").contains { $0.id == "targets" })
        XCTAssertEqual(InspectorSearchEntry.matches("tabaka a4").first?.id, "sheet.a4")
        XCTAssertTrue(InspectorSearchEntry.matches("giyotin dikey").contains { $0.id == "verticalCut" })
        XCTAssertTrue(InspectorSearchEntry.matches("firma teklif").contains { $0.id == "quoteCompany" })
        XCTAssertEqual(InspectorSearchEntry.matches("ton").first?.id, "artworkTone")
        XCTAssertTrue(InspectorSearchEntry.matches("parlaklık").isEmpty)
        XCTAssertTrue(InspectorSearchEntry.matches("  -- ").isEmpty)
        let entries = InspectorSearchEntry.entries
        XCTAssertEqual(Set(entries.map(\.panel)), Set(InspectorPanel.allCases))
        XCTAssertEqual(InspectorSearchEntry.byID.count, entries.count)
    }

    func testExistingFavoritesOpenRedistributedTools() throws {
        let store = preferences()
        let ids = ["artworkTone","colorBar","targets","sheetInfo","previewCrop","previewColor","colorInfo"]
        store.set(ids, forKey: "atispress.ui.inspectorFavorites")
        store.set("press", forKey: "atispress.ui.activePanel")
        let model = Workspace(uiDefaults: store)
        XCTAssertEqual(model.ui.activePanel,.color)
        XCTAssertEqual(model.ui.inspectorFavorites,ids)
        let before = try ProjectDocument(state: model.state).encoded()
        for (id, panel, group) in [
            ("artworkTone",InspectorPanel.color,InspectorGroup.tone), ("colorBar",.color,.colorControls),
            ("targets",.cut,.registration), ("sheetInfo",.output,.sheetInfo), ("previewCrop",.sheet,.preview),
            ("previewColor",.color,.colorControls), ("colorInfo",.color,.colorInfo)
        ] {
            let entry = try XCTUnwrap(InspectorSearchEntry.byID[id])
            XCTAssertTrue(model.openInspectorControl(entry))
            XCTAssertEqual(model.ui.activePanel,panel)
            XCTAssertTrue(model.ui.isGroupExpanded(group,in: panel,for: model.project))
            XCTAssertEqual(model.ui.groupRequest?.controlID,id)
        }
        XCTAssertEqual(try ProjectDocument(state: model.state).encoded(),before)
    }

    func testSelectOpensCollapsedFlyoutAndRequestsExactControlWithoutChangingProject() throws {
        let model = Workspace(uiDefaults: preferences())
        let before = try ProjectDocument(state: model.state).encoded()
        let entry = try XCTUnwrap(InspectorSearchEntry.byID["quoteCompany"])
        model.ui.inspectorCollapsed = true
        model.ui.search = "teklif firma"
        model.ui.setGroupExpanded(.quote, false)
        XCTAssertTrue(model.openInspectorControl(entry))
        XCTAssertEqual(model.ui.search, "")
        XCTAssertEqual(model.ui.activePanel, .price)
        XCTAssertEqual(model.ui.flyoutPanel, .price)
        XCTAssertTrue(model.ui.isGroupExpanded(.quote, in: .price, for: model.project))
        XCTAssertEqual(model.ui.groupRequest?.group, .quote)
        XCTAssertEqual(model.ui.groupRequest?.controlID, "quoteCompany")
        let firstRequest = model.ui.groupRequest
        XCTAssertTrue(model.openInspectorControl(entry))
        XCTAssertNotEqual(model.ui.groupRequest, firstRequest)
        XCTAssertEqual(try ProjectDocument(state: model.state).encoded(), before)

        let unavailable = try XCTUnwrap(InspectorSearchEntry.byID["targetSize"])
        XCTAssertFalse(model.openInspectorControl(unavailable))
        XCTAssertEqual(model.ui.groupRequest?.controlID, "quoteCompany")
    }

    func testSerialSearchSelectsExistingFieldAndFavoritesStayLocal() throws {
        let store = preferences()
        let model = Workspace(uiDefaults: store)
        let field = SerialField()
        model.editableSerialFields = [field]
        model.selectedSerialID = nil
        let serial = try XCTUnwrap(InspectorSearchEntry.byID["serialStart"])
        let before = try ProjectDocument(state: model.state).encoded()
        XCTAssertTrue(model.openInspectorControl(serial))
        XCTAssertEqual(model.selectedSerialID, field.id)
        XCTAssertEqual(model.ui.groupRequest?.controlID, serial.id)
        model.ui.toggleInspectorFavorite(serial.id)
        model.ui.toggleInspectorFavorite("previewColor")
        model.ui.toggleInspectorFavorite("unknown-id")
        XCTAssertEqual(UsabilitySettings(defaults: store).inspectorFavorites, [serial.id, "previewColor"])
        XCTAssertTrue(UsabilitySettings(defaults: preferences()).inspectorFavorites.isEmpty)
        XCTAssertEqual(try ProjectDocument(state: model.state).encoded(), before)
        model.ui.toggleInspectorFavorite(serial.id)
        XCTAssertEqual(UsabilitySettings(defaults: store).inspectorFavorites, ["previewColor"])
    }

    func testHostedInspectorSearchFocusesTextFieldInAnotherSection() async throws {
        let model = Workspace(uiDefaults: preferences())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prices = PricingStore(url: directory.appendingPathComponent("prices.json"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 740),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InspectorView(model: model, prices: prices))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.layoutIfNeeded()
        XCTAssertTrue(model.openInspectorControl(try XCTUnwrap(InspectorSearchEntry.byID["quoteCompany"])))
        for _ in 0..<100 {
            if let editor = window.firstResponder as? NSTextView,
               let field = editor.delegate as? NSTextField,
               field.placeholderString == "Firma adı (isteğe bağlı)" { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Arama hedefindeki metin alanı odaklanmadı: \(String(describing: window.firstResponder))")
    }
}
