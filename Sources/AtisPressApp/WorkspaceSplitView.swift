import SwiftUI
import AppKit

struct WorkspaceColumnLayout {
    static let pagesRange: ClosedRange<CGFloat> = 210...270
    static let minimumPreviewWidth: CGFloat = 500
    static let inspectorRange: ClosedRange<CGFloat> = 320...560
    static let railWidth: CGFloat = 72
    static let separatorWidth: CGFloat = 1
    static let gripWidth: CGFloat = 8
    private static let pageDividerAllowance: CGFloat = 2

    let windowWidth: CGFloat
    let railVisible: Bool
    let collapsed: Bool

    static func preferredWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return DesignSystem.inspectorWidth }
        return min(inspectorRange.upperBound, max(inspectorRange.lowerBound, width))
    }

    var maximumInspectorWidth: CGFloat {
        let available = windowWidth - Self.pagesRange.upperBound - Self.minimumPreviewWidth
            - Self.pageDividerAllowance - Self.gripWidth - railAndSeparator
        return Self.preferredWidth(max(Self.inspectorRange.lowerBound, available))
    }

    private var railAndSeparator: CGFloat {
        railVisible ? Self.railWidth + Self.separatorWidth : 0
    }

    func inspectorWidth(preferred: CGFloat, translation: CGFloat = 0) -> CGFloat {
        let limit = maximumInspectorWidth
        let start = min(Self.preferredWidth(preferred), limit)
        guard translation.isFinite else { return start }
        return min(limit, max(Self.inspectorRange.lowerBound, start - translation))
    }

    func dockWidth(preferred: CGFloat, translation: CGFloat = 0) -> CGFloat {
        if collapsed { return Self.railWidth }
        return inspectorWidth(preferred: preferred, translation: translation) + railAndSeparator
    }
}

struct WorkspaceSplitView<Pages: View, Preview: View, Tools: View>: View {
    @ObservedObject var settings: UsabilitySettings
    let windowWidth: CGFloat
    @ViewBuilder var pages: Pages
    @ViewBuilder var preview: Preview
    @ViewBuilder var tools: Tools
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var gripHovered = false

    private var columns: WorkspaceColumnLayout {
        WorkspaceColumnLayout(windowWidth: windowWidth, railVisible: settings.railVisible,
                              collapsed: settings.inspectorCollapsed)
    }

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                pages.frame(minWidth: WorkspaceColumnLayout.pagesRange.lowerBound, idealWidth: 230,
                            maxWidth: WorkspaceColumnLayout.pagesRange.upperBound)
                preview.frame(minWidth: WorkspaceColumnLayout.minimumPreviewWidth,
                              maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if settings.inspectorCollapsed {
                Rectangle().fill(DesignSystem.border).frame(width: WorkspaceColumnLayout.separatorWidth)
            } else {
                grip
            }
            tools.frame(width: columns.dockWidth(preferred: settings.inspectorWidth, translation: dragTranslation))
        }
    }

    private var grip: some View {
        ZStack {
            Rectangle().fill(DesignSystem.border).frame(width: WorkspaceColumnLayout.separatorWidth)
            Capsule().fill(gripHovered || dragTranslation != 0 ? DesignSystem.teal : DesignSystem.muted)
                .frame(width: 3, height: 28)
        }
        .frame(width: WorkspaceColumnLayout.gripWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($dragTranslation) { value, translation, transaction in
                transaction.animation = nil
                translation = value.translation.width
            }
            .onEnded { resize(by: $0.translation.width) })
        .onHover(perform: setGripHovered)
        .onDisappear { setGripHovered(false) }
        .help("Panel genişliğini değiştirmek için sürükleyin.")
        .accessibilityLabel("Ayar paneli genişliği")
        .accessibilityValue("\(Int(columns.inspectorWidth(preferred: settings.inspectorWidth, translation: dragTranslation))) punto")
        .accessibilityIdentifier("sidebar.resize")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: resize(by: -16)
            case .decrement: resize(by: 16)
            @unknown default: break
            }
        }
    }

    private func resize(by translation: CGFloat) {
        let width = columns.inspectorWidth(preferred: settings.inspectorWidth, translation: translation)
        if width != columns.inspectorWidth(preferred: settings.inspectorWidth) {
            settings.setInspectorWidth(width)
        }
    }

    private func setGripHovered(_ inside: Bool) {
        guard inside != gripHovered else { return }
        gripHovered = inside
        if inside { NSCursor.resizeLeftRight.push() }
        else { NSCursor.pop() }
    }
}
