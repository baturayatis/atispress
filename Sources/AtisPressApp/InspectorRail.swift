import SwiftUI
import ImpositionCore

extension Workspace {
    func panelHasIndicator(_ panel:InspectorPanel) -> Bool {
        if InspectorRegistry.fields(panel).contains(where:{isManual($0) || project.autoLayout?.presetFields?.contains($0)==true}) {return true}
        if panel == .coverPreparation { return project.coverPreparation != nil }
        if panel == .job && basicQuantity != nil {return true}
        if panel == .serial && !editableSerialFields.isEmpty {return true}
        if panel == .dimensions && project.hasRescaling {return true}
        if panel == .separation && (project.sourcePreparation?.hasPreparedProducts == true || !(project.sourcePreparation?.hiddenGuideGroups.isEmpty ?? true)) {return true}
        if panel == .montage && (project.team != nil || workflowIssues.contains { $0.code == .gangLayout }) {return true}
        if panel == .price,let cost=project.costing,cost.margin != nil || cost.vat != nil {return true}
        if panel == .dimensions && showsMissingBleedWarning {return true}
        return workflowIssues.contains {InspectorPanel.legacy(inspectorSection(for:$0))==panel}
    }
}

struct InspectorDock:View {
    @ObservedObject var model:Workspace
    @ObservedObject var prices:PricingStore
    var body:some View {
        HStack(spacing:0) {
            if !model.ui.inspectorCollapsed {
                VStack(spacing: 0) {
                    if !model.ui.railVisible {
                        HStack {
                            Spacer()
                            InspectorVisibilityButton(settings: model.ui)
                        }.padding(.horizontal, 12).padding(.top, 8)
                    }
                    InspectorView(model: model, prices: prices)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignSystem.card)
            }
            if model.ui.railVisible {
                if !model.ui.inspectorCollapsed {
                    Rectangle().fill(DesignSystem.border).frame(width: WorkspaceColumnLayout.separatorWidth)
                }
                InspectorRail(model:model,prices:prices)
            }
        }.onChange(of: model.ui.revealedSection, initial: true) { _, section in
            guard let section else { return }
            let group: InspectorGroup?
            switch section {
            case .edges:
                model.ui.detailsExpanded = true
                group = .edges
            case .marks:
                group = model.ui.focusedArea == .gutter ? .edges : .bleed
            case .serial:
                model.ui.expandedAddons.insert(.serial)
                group = .serialFields
            case .price:
                model.ui.expandedAddons.insert(.pricing)
                group = .cost
            case .binding:
                let destination = InspectorGroup.bindingEntry(for: model.project)
                group = InspectorPanel.montage.groups(for: model.project).contains(destination) ? destination : nil
            default:
                group = nil
            }
            model.ui.collapsedCards = []
            model.ui.jump(InspectorPanel.legacy(section), opening: group)
            model.ui.revealedSection = nil
        }
    }
}

struct InspectorRail:View {
    @ObservedObject var model:Workspace
    @ObservedObject var prices:PricingStore
    @FocusState private var focused:InspectorPanel?
    private var panels:[InspectorPanel] {InspectorPanel.allCases}
    var body:some View {
        VStack(spacing:2) {
            InspectorVisibilityButton(settings: model.ui)
            Divider()
            ForEach(panels) {panel in
                item(panel).focused($focused,equals:panel)
            }
            Spacer(minLength:4)
        }.padding(.horizontal,2).frame(width:WorkspaceColumnLayout.railWidth).background(DesignSystem.card)
            .onMoveCommand {direction in
                let step=direction == .down ? 1 : direction == .up ? -1 : 0
                guard let next=InspectorPanel.neighbor(of:focused ?? model.ui.activePanel,step:step,visible:panels) else {return}
                focused=next
                model.ui.jump(next)
            }
            .popover(item:Binding(get:{model.ui.flyoutPanel},set:{model.ui.flyoutPanel=$0}),arrowEdge:.leading) {panel in
                InspectorView(model:model,prices:prices,only:panel).frame(width:350,height:720)
            }
    }
    private func item(_ panel:InspectorPanel) -> some View {
        let selected=model.ui.activePanel==panel
        let shortcuts = InspectorPanel.shortcuts.filter { $0.panel == panel && $0.isAvailable(for: model.project) }
        let shortcutHelp = shortcuts.map(\.displayShortcut).joined(separator: ", ")
        return Button {model.ui.jump(panel)} label: {
            VStack(spacing:3) {
                ZStack(alignment:.topTrailing) {
                    Image(systemName:panel.symbol).font(.system(size:17)).frame(width:24,height:20)
                    if model.panelHasIndicator(panel) {Circle().fill(DesignSystem.warning).frame(width:5,height:5).offset(x:5,y:-1)}
                }
                Text(panel.title).font(.system(size:12)).lineLimit(1).minimumScaleFactor(0.75)
            }.frame(width:68,height:48)
                .foregroundStyle(selected ? DesignSystem.selectedText : DesignSystem.text)
                .background(selected ? DesignSystem.selected : Color.clear,in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).focusable()
            .help(panel.help + (shortcutHelp.isEmpty ? "" : " · " + shortcutHelp))
            .accessibilityLabel(panel.title+" bölümü")
            .accessibilityValue(model.panelHasIndicator(panel) ? "Manuel ayar veya uyarı var" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("rail.section."+panel.rawValue)
    }
}


private struct InspectorVisibilityButton: View {
    @ObservedObject var settings: UsabilitySettings
    private var title: String { settings.inspectorCollapsed ? "Aç" : "Daralt" }
    private var description: String { settings.inspectorCollapsed ? "Ayar panelini aç" : "Ayar panelini daralt" }

    var body: some View {
        Button {
            settings.inspectorCollapsed.toggle()
        } label: {
            Label(title, systemImage: settings.inspectorCollapsed ? "sidebar.right" : "sidebar.trailing")
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.vertical, 4)
        .help(description)
        .accessibilityLabel(description)
        .accessibilityIdentifier("sidebar.visibility")
    }
}
