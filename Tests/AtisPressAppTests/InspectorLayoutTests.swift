import AppKit
import SwiftUI
import XCTest
@testable import AtisPressApp

@MainActor
final class InspectorLayoutTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "InspectorLayoutTests." + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    func testResizeLimitsRespectWindowAndStartFromVisibleWidth() {
        let wide = WorkspaceColumnLayout(windowWidth: 1500, railVisible: true, collapsed: false)
        XCTAssertEqual(wide.inspectorWidth(preferred: 350, translation: -1000), 560)
        XCTAssertEqual(wide.inspectorWidth(preferred: 350, translation: 1000), 320)
        XCTAssertEqual(wide.inspectorWidth(preferred: 350, translation: -40), 390)
        XCTAssertEqual(wide.dockWidth(preferred: 350), 423)

        let small = WorkspaceColumnLayout(windowWidth: DesignSystem.minimumWindow.width, railVisible: true, collapsed: false)
        let visible = small.inspectorWidth(preferred: 520)
        XCTAssertLessThan(visible, 520)
        XCTAssertEqual(small.inspectorWidth(preferred: 520, translation: 5), visible - 5)
        XCTAssertGreaterThanOrEqual(small.windowWidth - small.dockWidth(preferred: 520)
                                   - WorkspaceColumnLayout.gripWidth - WorkspaceColumnLayout.pagesRange.upperBound - 2,
                                   WorkspaceColumnLayout.minimumPreviewWidth)

        let withoutRail = WorkspaceColumnLayout(windowWidth: small.windowWidth, railVisible: false, collapsed: false)
        XCTAssertEqual(withoutRail.dockWidth(preferred: 520), withoutRail.inspectorWidth(preferred: 520))
        XCTAssertGreaterThan(withoutRail.maximumInspectorWidth, small.maximumInspectorWidth)
        let collapsed = WorkspaceColumnLayout(windowWidth: small.windowWidth, railVisible: true, collapsed: true)
        XCTAssertEqual(collapsed.dockWidth(preferred: 520), WorkspaceColumnLayout.railWidth)
    }

    func testRestoresWidthVisibilityAndSectionOverridesWithoutProjectChanges() throws {
        let store = defaults()
        let model = Workspace(uiDefaults: store)
        let before = try ProjectDocument(state: model.state).encoded()
        XCTAssertEqual(model.ui.inspectorWidth, DesignSystem.inspectorWidth)
        XCTAssertTrue(model.ui.inspectorFavoritesExpanded)

        model.ui.setInspectorWidth(492)
        model.ui.setGroupExpanded(.edges, false)
        model.ui.setGroupExpanded(.scale, true)
        model.ui.inspectorFavoritesExpanded = false
        model.ui.toggleInspectorFavorite("scale")
        model.ui.inspectorCollapsed = true

        let restored = Workspace(uiDefaults: store)
        XCTAssertEqual(restored.ui.inspectorWidth, 492)
        XCTAssertTrue(restored.ui.inspectorCollapsed)
        XCTAssertTrue(restored.ui.railVisible)
        XCTAssertFalse(restored.ui.isGroupExpanded(.edges, in: .dimensions, for: restored.project))
        XCTAssertTrue(restored.ui.isGroupExpanded(.scale, in: .dimensions, for: restored.project))
        XCTAssertTrue(restored.ui.isGroupExpanded(.bleed, in: .dimensions, for: restored.project))
        XCTAssertFalse(restored.ui.inspectorFavoritesExpanded)
        XCTAssertEqual(restored.ui.inspectorFavorites, ["scale"])
        let restoredBefore = try ProjectDocument(state: restored.state).encoded()
        restored.ui.railVisible = false
        let railHidden = Workspace(uiDefaults: store)
        XCTAssertFalse(railHidden.ui.railVisible)
        XCTAssertFalse(railHidden.ui.inspectorCollapsed)
        XCTAssertEqual(railHidden.ui.inspectorWidth, 492)
        XCTAssertEqual(try ProjectDocument(state: model.state).encoded(), before)
        XCTAssertEqual(try ProjectDocument(state: restored.state).encoded(), restoredBefore)
        XCTAssertEqual(railHidden.project, model.project)
    }

    func testInvalidLocalLayoutPreferencesFallBackOrClamp() {
        let store = defaults()
        store.set(999, forKey: "atispress.ui.inspectorWidth")
        store.set(["edges": "unknown", "oldGroup": false, "scale": true], forKey: "atispress.ui.inspectorSections")
        let ui = UsabilitySettings(defaults: store)
        let project = Workspace.newProject()
        XCTAssertEqual(ui.inspectorWidth, WorkspaceColumnLayout.inspectorRange.upperBound)
        XCTAssertTrue(ui.isGroupExpanded(.edges, in: .dimensions, for: project))
        XCTAssertTrue(ui.isGroupExpanded(.scale, in: .dimensions, for: project))
        ui.setInspectorWidth(.infinity)
        XCTAssertEqual(ui.inspectorWidth, DesignSystem.inspectorWidth)
    }

    func testHostedLayoutFreesPreviewWidthAndRestoresAfterWindowShrinks() async throws {
        struct Widths {
            var preview: CGFloat = 0
            var dock: CGFloat = 0
            var pages: CGFloat = 0
        }
        var measured = Widths()
        let ui = UsabilitySettings(defaults: defaults())
        ui.setInspectorWidth(500)
        let content = GeometryReader { geometry in
            WorkspaceSplitView(settings: ui, windowWidth: geometry.size.width) {
                Color.blue.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured.pages = $0 }
            } preview: {
                Color.green.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured.preview = $0 }
            } tools: {
                Color.red.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured.dock = $0 }
            }
        }
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 1450, height: 740)

        func settle(dockWidth: CGFloat) async throws {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if abs(measured.dock - dockWidth) < 1, measured.preview > 0, measured.pages > 0 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Beklenen panel genişliği \(dockWidth), ölçülen \(measured.dock)")
        }

        try await settle(dockWidth: 573)
        let expanded = measured
        ui.setInspectorWidth(450)
        try await settle(dockWidth: 523)
        XCTAssertEqual(measured.pages, expanded.pages, accuracy: 2)
        XCTAssertEqual(measured.preview - expanded.preview, 50, accuracy: 2)
        ui.setInspectorWidth(500)
        try await settle(dockWidth: 573)
        ui.inspectorCollapsed = true
        try await settle(dockWidth: 72)
        XCTAssertEqual(measured.pages, expanded.pages, accuracy: 2)
        XCTAssertEqual(measured.preview - expanded.preview, 508, accuracy: 2)
        ui.inspectorCollapsed = false
        try await settle(dockWidth: 573)

        host.setFrameSize(CGSize(width: DesignSystem.minimumWindow.width, height: 740))
        let small = WorkspaceColumnLayout(windowWidth: DesignSystem.minimumWindow.width, railVisible: true, collapsed: false)
        try await settle(dockWidth: small.dockWidth(preferred: 500))
        XCTAssertGreaterThanOrEqual(measured.preview, WorkspaceColumnLayout.minimumPreviewWidth - 1)
        XCTAssertEqual(ui.inspectorWidth, 500)

        host.setFrameSize(CGSize(width: 1450, height: 740))
        try await settle(dockWidth: 573)
        XCTAssertEqual(measured.preview, expanded.preview, accuracy: 2)
    }
}
