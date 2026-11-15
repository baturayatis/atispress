import SwiftUI
import ImpositionCore

extension Workspace {
    func panelHasIndicator(_ panel:InspectorPanel) -> Bool {
        if InspectorRegistry.fields(panel).contains(where:{isManual($0) || project.autoLayout?.presetFields?.contains($0)==true}) {return true}
        if panel == .job && basicQuantity != nil {return true}
        if panel == .serial && !editableSerialFields.isEmpty {return true}
        if panel == .scaling && (project.hasRescaling || project.sourcePreparation?.split != nil || !(project.sourcePreparation?.hiddenGuideGroups.isEmpty ?? true)) {return true}
        if panel == .price,let cost=project.costing,cost.margin != nil || cost.vat != nil {return true}
        if panel == .bleed && showsMissingBleedWarning {return true}
        return workflowIssues.contains {InspectorPanel.legacy(inspectorSection(for:$0))==panel}
    }
}

struct InspectorDock:View {
    @ObservedObject var model:Workspace
    @ObservedObject var prices:PricingStore
    var body:some View {
        HStack(spacing:0) {
            if !model.ui.inspectorCollapsed {InspectorView(model:model,prices:prices).frame(minWidth:370,idealWidth:DesignSystem.inspectorWidth,maxWidth:.infinity)}
            if model.ui.railVisible {
                Divider()
                InspectorRail(model:model,prices:prices)
            }
        }.onChange(of:model.project.binding) {_,_ in
            if !InspectorPanel.visible(for:model.project).contains(model.ui.activePanel) {model.ui.jump(.job)}
        }
    }
}

struct InspectorRail:View {
    @ObservedObject var model:Workspace
    @ObservedObject var prices:PricingStore
    @FocusState private var focused:InspectorPanel?
    private var panels:[InspectorPanel] {InspectorPanel.visible(for:model.project)}
    var body:some View {
        VStack(spacing:2) {
            header
            Divider()
            ForEach(panels) {panel in
                item(panel).focused($focused,equals:panel)
            }
            Spacer(minLength:4)
            footer
        }.padding(.horizontal,2).frame(width:56).background(DesignSystem.card)
            .onMoveCommand {direction in
                let step=direction == .down ? 1 : direction == .up ? -1 : 0
                guard let next=InspectorPanel.neighbor(of:focused ?? model.ui.activePanel,step:step,visible:panels) else {return}
                focused=next
                model.ui.jump(next)
            }
            .popover(item:Binding(get:{model.ui.flyoutPanel},set:{model.ui.flyoutPanel=$0}),arrowEdge:.leading) {panel in
                InspectorView(model:model,prices:prices,only:panel).frame(width:400,height:620)
            }
    }
    private var header:some View {
        VStack(spacing:2) {
            Image(systemName:model.ui.inspectorCollapsed ? "sidebar.right" : "sidebar.trailing")
            Text("Ayarlar").font(.system(size:9))
        }.frame(width:52,height:34).contentShape(Rectangle())
            .onTapGesture(count:2) {model.ui.inspectorCollapsed.toggle()}
            .focusable().onKeyPress(.return) {model.ui.inspectorCollapsed.toggle();return .handled}
            .help("Denetçiyi daralt veya aç · çift tıklayın")
            .accessibilityElement(children:.ignore).accessibilityLabel("Denetçiyi daralt veya aç")
            .accessibilityAddTraits(.isButton).accessibilityAction {model.ui.inspectorCollapsed.toggle()}
    }
    private func item(_ panel:InspectorPanel) -> some View {
        let selected=model.ui.activePanel==panel
        return Button {model.ui.jump(panel)} label: {
            VStack(spacing:3) {
                ZStack(alignment:.topTrailing) {
                    Image(systemName:panel.symbol).font(.system(size:17)).frame(width:24,height:20)
                    if model.panelHasIndicator(panel) {Circle().fill(DesignSystem.warning).frame(width:5,height:5).offset(x:5,y:-1)}
                }
                Text(panel.shortTitle).font(.system(size:9)).lineLimit(1)
            }.frame(width:52,height:44)
                .foregroundStyle(selected ? DesignSystem.selectedText : DesignSystem.text)
                .background(selected ? DesignSystem.selected : Color.clear,in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).focusable()
            .help(panel.title+" · ⌘"+String(panel.number))
            .accessibilityLabel(panel.title+" bölümü, Komut "+String(panel.number))
            .accessibilityValue(model.panelHasIndicator(panel) ? "Manuel ayar veya uyarı var" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("rail.section."+panel.rawValue)
    }
    private var footer:some View {
        VStack(spacing:3) {
            Button {model.ui.collapseAllPanels()} label: {Text("Tümünü\ndaralt").font(.system(size:9)).multilineTextAlignment(.center).frame(width:52,height:28)}
                .buttonStyle(.plain).help("Tümünü daralt").accessibilityLabel("Tümünü daralt")
            Button {model.ui.expandAllPanels()} label: {Text("Tümünü\naç").font(.system(size:9)).multilineTextAlignment(.center).frame(width:52,height:28)}
                .buttonStyle(.plain).help("Tümünü aç").accessibilityLabel("Tümünü aç")
            Toggle(isOn:Binding(get:{model.ui.accordion},set:{model.ui.accordion=$0})) {Text("Tek bölüm").font(.system(size:8))}
                .toggleStyle(.checkbox).labelsHidden().help("Tek bölüm göster").accessibilityLabel("Tek bölüm göster")
            Text("Tek bölüm").font(.system(size:8)).padding(.bottom,5)
        }
    }
}
