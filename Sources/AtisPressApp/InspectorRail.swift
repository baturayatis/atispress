import SwiftUI
import ImpositionCore

extension Workspace {
    func panelHasIndicator(_ panel:InspectorPanel) -> Bool {
        if InspectorRegistry.fields(panel).contains(where:{isManual($0) || project.autoLayout?.presetFields?.contains($0)==true}) {return true}
        if panel == .job && basicQuantity != nil {return true}
        if panel == .serial && !editableSerialFields.isEmpty {return true}
        if panel == .scaling && project.hasRescaling {return true}
        if panel == .separation && (project.sourcePreparation?.hasPreparedProducts == true || !(project.sourcePreparation?.hiddenGuideGroups.isEmpty ?? true)) {return true}
        if panel == .color && (project.imageColorJobs?.isEmpty == false || project.gang?.jobs.contains { $0.imageColor != nil } == true || colorVariants?.warnings.isEmpty == false) {return true}
        if panel == .montage && (project.team != nil || workflowIssues.contains { $0.code == .gangLayout }) {return true}
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
            if !model.ui.inspectorCollapsed {InspectorView(model:model,prices:prices).frame(minWidth:320,idealWidth:DesignSystem.inspectorWidth,maxWidth:.infinity)}
            if model.ui.railVisible {
                Divider()
                InspectorRail(model:model,prices:prices)
            }
        }.onAppear {
            if !InspectorPanel.visible(for:model.project).contains(model.ui.activePanel) {model.ui.jump(.job)}
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
        }.padding(.horizontal,2).frame(width:72).background(DesignSystem.card)
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
    private var header:some View {
        VStack(spacing:2) {
            Image(systemName:model.ui.inspectorCollapsed ? "sidebar.right" : "sidebar.trailing")
            Text("Ayarlar").font(.system(size:12))
        }.frame(width:68,height:34).contentShape(Rectangle())
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
                Text(panel.shortTitle).font(.system(size:12)).lineLimit(1)
            }.frame(width:68,height:48)
                .foregroundStyle(selected ? DesignSystem.selectedText : DesignSystem.text)
                .background(selected ? DesignSystem.selected : Color.clear,in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).focusable()
            .help(panel.help+(panel.number<=9 ? " · ⌘"+String(panel.number) : ""))
            .accessibilityLabel(panel.title+" bölümü"+(panel.number<=9 ? ", Komut "+String(panel.number) : ""))
            .accessibilityValue(model.panelHasIndicator(panel) ? "Manuel ayar veya uyarı var" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("rail.section."+panel.rawValue)
    }
}
