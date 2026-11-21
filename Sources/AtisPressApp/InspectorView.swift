import SwiftUI
import AppKit
import ImpositionCore

struct InspectorView: View {
    @ObservedObject var model: Workspace
    @ObservedObject var prices:PricingStore
    @State private var focusedMeasurement: String?
    var only: InspectorPanel? = nil
    private var panel:InspectorPanel {only ?? model.ui.activePanel}
    private var groups: [InspectorGroup] {panel.groups(for:model.project)}
    private var manualFields:[AutoLayoutField] {
        InspectorRegistry.fields(panel).filter {model.isManual($0) || model.project.autoLayout?.presetFields?.contains($0)==true}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            InspectorSearchView(model: model)
            Label(panel.title,systemImage:panel.symbol).font(.system(size:17,weight:.semibold))
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("panel.header."+panel.rawValue)
            if !manualFields.isEmpty {
                Button("\(manualFields.count) ayar manuel · Otomatiğe döndür") { model.returnToAutomatic(manualFields) }
                    .buttonStyle(.link).font(.system(size:12))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    sections
                }
                .accessibilityIdentifier("panel.localScroll")
                .task(id: model.ui.groupRequest) {
                    guard let request = model.ui.groupRequest, groups.contains(request.group) else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if let id = request.controlID { proxy.scrollTo(id, anchor: .center) }
                    else { proxy.scrollTo(request.group, anchor: .top) }
                }
            }.id(panel)
        }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .font(.system(size:13)).controlSize(.large)
            .background(DesignSystem.card).environmentObject(model).tint(DesignSystem.teal)
            .environment(\.inspectorTargetContext, InspectorTargetContext(request: model.ui.groupRequest))
            .accessibilityElement(children:.contain).accessibilityLabel(panel.title+" paneli")
            .accessibilityIdentifier("panel."+panel.rawValue)
            .disabled(model.loading || model.preparingSource || model.autoArranging)
            .task {model.refreshWorkflowRecommendation()}
            .onChange(of:model.project) {_,_ in model.refreshWorkflowRecommendation()}
    }
    private var usingMachineProfile: Bool {
        model.project.supportsMachineProfile && model.project.machineProfile != nil
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { model.ui.isGroupExpanded(group, in: panel, for: model.project) },
                    set: { model.ui.setGroupExpanded(group, $0) }
                )) {
                    VStack(alignment: .leading, spacing: 10) { sectionContent(group) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } label: {
                    Text(group.title).fontWeight(.semibold)
                        .accessibilityIdentifier("panel.section." + group.rawValue)
                }
                .id(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func sectionContent(_ group: InspectorGroup) -> some View {
        switch group {
        case .jobBasics:
            workflowProduct
            if model.project.binding == .stepAndRepeat {Toggle("Adet hesapla (her iş için)",isOn:model.optionalCountBinding($model.project.stepAndRepeat.quantity,name:"quantity",defaultValue:1000)).inspectorTarget("countQuantity")}
        case .method: methodControls
        case .waste: FireControlsView(model:model)
        case .presets: PresetInspectorView(model:model)
        case .paper:
            if model.project.supportsMachineProfile { MachineProfileView(model: model) }
            if !usingMachineProfile {
                workflowPaper
                sheetControls
            }
        case .products: montageProducts
        case .placement: placementControls
        case .jobFaces: jobFaceControls.disabled(usingMachineProfile && model.project.machineProfile?.faces == .single)
        case .binding:
            if model.project.isLeafBinding { LeafInspectorView(model:model,section:0) }
            else { signatureControls }
        case .coverPreparation: CoverPreparationView(model:model)
        case .cover,.bookPaper,.spine: BookInspectorView(model:model)
        case .blanks: BlankPlacementInspector(model:model)
        case .edges:
            edgeControls.disabled(usingMachineProfile)
            Picker("Hizalama",selection:model.autoBinding($model.project.blockAlignment,.alignment)) {
                Text("Ortala").tag(BlockAlignment.center);Text("Maşaya yasla").tag(BlockAlignment.gripper)
            }.pickerStyle(.segmented).inspectorTarget("alignment").automaticReset(model,.alignment).disabled(usingMachineProfile)
        case .bleed: workflowBleed
        case .generatedBleed: generatedBleedControls
        case .scale:
            RescaleInspectorView(model:model)
            if let prompt=model.rescalePrompt {ScalingSuggestionBanner(model:model,prompt:prompt)}
        case .printedMarks: ExportMarksView(model:model,inline:true,scope:.printed)
        case .internalCuts: InternalCutMarksView(model: model)
        case .cutMeasures: markControls
        case .separation:
            SourcePageTools(model:model)
            if !model.canSeparateArtwork {
                Text("İş ayırmak için tek sayfalı, tek kaynaklı bir düz PDF işi seçin.").foregroundStyle(DesignSystem.muted)
            }
        case .serialFields: SerialInspectorView(model:model,compact:true,section:0)
        case .serialContent: SerialInspectorView(model:model,compact:true,section:1)
        case .serialRange: SerialInspectorView(model:model,compact:true,section:2)
        case .serialAppearance: SerialInspectorView(model:model,compact:true,section:3)
        case .serialPosition: SerialInspectorView(model:model,compact:true,section:4)
        case .production: productionControl
        case .tone: ToneControls(model: model)
        case .colorControls: ExportMarksView(model:model,inline:true,scope:.colorControls)
        case .colorSizes: ColorControlSizeView(model:model,scope:.scale)
        case .colorInfo:
            PreflightView(model:model,colorOnly:true).inspectorTarget("colorInfo")
        case .registration:
            ExportMarksView(model:model,inline:true,scope:.registration)
            ColorControlSizeView(model:model,scope:.registration)
        case .sheetInfo: ExportMarksView(model:model,inline:true,scope:.info)
        case .preview:
            overlayControls
            previewColorControl
            previewRegistrationControl
        case .cost: CostingView(model:model,store:prices,inline:true,section:0)
        case .labor: CostingView(model:model,store:prices,inline:true,section:1)
        case .result: CostingView(model:model,store:prices,inline:true,section:2)
        case .quote: CostingView(model:model,store:prices,inline:true,section:3)
        case .priceLibrary: PricingView(store:prices,inline:true)
        case .output:
            Button("PDF’i Hazırla") {model.preparingExport=true}.disabled(!model.canExportNow).inspectorTarget("preparePDF")
            ForEach(ExportPreset.allCases,id:\.self) {preset in
                Button(preset.rawValue) {model.project.exportMarks=preset.applying(to:model.project.exportMarks)}.frame(minHeight:30)
            }
            ExportMarksView(model:model,inline:true,scope:.options)
        case .preflight: PreflightView(model:model)
        }
    }

    @ViewBuilder private var montageProducts: some View {
        if model.project.binding == .gang {
            if model.project.team != nil { TeamInspectorView(model: model) }
            else { GangInspectorView(model:model) }
        } else if model.project.binding == .stepAndRepeat {
            if model.canStartTeam { Button("Takım olarak diz", action: model.startTeam).inspectorTarget("startTeam") }
            if (model.source?.pages.count ?? model.project.pages.count) > 1 {
                Picker("Sayfa düzeni",selection: Binding(get: { model.pageLayoutMode },set: model.setPageLayout)) {
                    Text("Otomatik").tag(PageLayout.automatic)
                    Text("Çift yüz").tag(PageLayout.duplex)
                    Text("Tek yüz").tag(PageLayout.simplex)
                }.pickerStyle(.segmented).inspectorTarget("pageLayout").inspectorSetting(model,"Sayfa düzeni",SettingGuidance.detail("Sayfa düzeni"))
            }
            Text(model.pageLayoutSummary).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }
    }

    private var jobFaceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.project.repeatJobs.enumerated()),id:\.offset) {index,job in
                Picker("İş \(index+1) yüzleri",selection:Binding(get:{model.jobPageLayout(frontPage:job.front.number)},set:{model.setJobPageLayout(frontPage:job.front.number,mode:$0)})) {
                    Text("Genel ayar").tag(PageLayout.automatic);Text("Tek yüz").tag(PageLayout.simplex);Text("Çift yüz").tag(PageLayout.duplex)
                }
            }
        }
    }

    @ViewBuilder private var placementControls: some View {
        if model.project.binding == .stepAndRepeat { repeatControls }
        if !usingMachineProfile {
            if model.showsTurnControl { turnControls }
            else if model.project.binding != .stepAndRepeat {
                Text("Çevirme ayarı çift yüzlü işlerde kullanılabilir.").foregroundStyle(DesignSystem.muted)
            }
        }
    }

    private var turnControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Ön/arka çevirme",selection:$model.project.settings.turnMethod) {
                Text("Ayrı kalıp").tag(TurnMethod.sheetwise).help("Ön ve arka için ayrı kalıp")
                Text("Yandan").tag(TurnMethod.workAndTurn).help("Tabakayı yan kenarından çevir")
                Text("Baştan").tag(TurnMethod.workAndTumble).help("Tabakayı baş kenarından çevir")
            }.pickerStyle(.segmented).inspectorTarget("turn")
            Text(model.turnHelper).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1).help(model.turnHelper)
        }
    }

    private var workflowProduct:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            Text(model.workflowProductSummary).font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
            Picker("Ürün tipi",selection:Binding(get:{ model.productKind },set:model.setProductKind)) {
                ForEach(ProductKind.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }.inspectorTarget("product")
            HStack(spacing:DesignSystem.Space.sm) {
                Text("Adet").frame(maxWidth:.infinity,alignment:.leading)
                TextField("örn. 1000",value:Binding<Int?>(get:{ model.basicQuantity },set:{ model.basicQuantity = $0 }),format:.number.locale(TRFormat.locale))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Adet").accessibilityIdentifier("setting.quantity").frame(width:72).inspectorTarget("quantity")
                Text("adet").font(.system(size:12)).foregroundStyle(DesignSystem.muted).fixedSize().frame(width:32,alignment:.leading)
                Stepper("Adet",value:Binding(get:{ model.basicQuantity ?? 1 },set:{ model.basicQuantity = $0 }),in:1...100000000).labelsHidden().fixedSize()
            }
            if model.project.isBooklet || model.project.isLeafBinding { Text("Yayın adedi maliyet hesabı içindir; PDF tek yayın planını korur.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1) }
            HStack(spacing:DesignSystem.Space.sm) {
                Text("Fire").help("Ek üretim payı").frame(maxWidth:.infinity,alignment:.leading)
                TextField("0",value:Binding(get:{ model.workflowWastePercent },set:{ model.workflowWastePercent = $0 }),format:.number.locale(TRFormat.locale))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Fire yüzdesi").accessibilityIdentifier("setting.waste.percent").frame(width:72).inspectorTarget("wastePercent")
                Text("%").font(.system(size:12)).foregroundStyle(DesignSystem.muted).fixedSize().frame(width:32,alignment:.leading)
                Stepper("Fire",value:Binding(get:{ model.workflowWastePercent },set:{ model.workflowWastePercent = $0 }),in:0...100).labelsHidden().fixedSize()
            }
            Text(model.workflowWaste.mode == .fixed ? "Sabit fire ayrıntılarda korunuyor." : "Fire: ek üretim payı.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }
    }
    private var workflowPaper:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            LazyVGrid(columns:[GridItem(.adaptive(minimum:76),spacing:DesignSystem.Space.sm)],spacing:DesignSystem.Space.sm) {
                ForEach(WorkflowPresentation.sheetChips,id:\.self) { chip in
                    Button { model.selectWorkflowSheet(chip) } label: {
                        Text(chip).font(.callout.weight(.medium)).frame(maxWidth:.infinity,minHeight:30)
                            .foregroundStyle(model.selectedWorkflowChip == chip ? DesignSystem.selectedText : DesignSystem.text)
                            .background(model.selectedWorkflowChip == chip ? DesignSystem.selected : DesignSystem.workspace,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
                    }.buttonStyle(.plain).accessibilityLabel("Tabaka \(chip)").accessibilityAddTraits(model.selectedWorkflowChip == chip ? .isSelected : [])
                        .inspectorTarget(InspectorSearchEntry.sheetID(chip))
                }
            }
            OrientationPicker("Yön",selection:Binding(get:{ (model.project.autoLayout ?? .legacy).isFixed(.orientation) ? model.project.sheet.orientation : .auto },set:model.selectWorkflowOrientation), inspectorID: "orientation").id("orientation").automaticReset(model,.orientation)


            let selectedSize = model.project.sheet.size
            Text(model.workflowOrientationSummary).help(TRFormat.size(selectedSize.width,selectedSize.height)).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
            if model.sheetPreset == "Özel" {
                measurement("Genişlik",$model.project.sheet.size.width,autoField:.sheetSize,range:20...3000,id:"sheetWidth")
                measurement("Yükseklik",$model.project.sheet.size.height,autoField:.sheetSize,range:20...3000,id:"sheetHeight")
            }
            if let recommendation = model.visibleWorkflowRecommendation {
                VStack(alignment:.leading,spacing:DesignSystem.Space.sm) {
                    Label(model.workflowRecommendationText(recommendation),systemImage:"info.circle")
                        .font(.system(size:12).weight(.medium))
                    Button { model.returnToAutomaticSheet() } label: { Text("Öneriyi uygula").foregroundStyle(DesignSystem.success) }.buttonStyle(.borderless).font(.system(size:12).weight(.semibold))
                }.padding(DesignSystem.Space.md).frame(maxWidth:.infinity,alignment:.leading)
                    .foregroundStyle(DesignSystem.success).background(DesignSystem.successSurface,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
            }

        }
    }
    private var productionControl: some View {
        Picker("Üretim",selection:Binding(get:{ model.project.autoLayout?.production ?? .digital },set:model.setProduction)) {
            Text("Dijital").tag(ProductionType.digital)
            Text("Ofset").tag(ProductionType.offset)
        }.pickerStyle(.segmented).inspectorTarget("production")
    }
    private var workflowBleed:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            HStack(spacing:8) {
                Text("Taşma payı").frame(maxWidth:.infinity,alignment:.leading)
                Toggle("Eksik taşmayı üret",isOn:model.autoBinding($model.editableGeneratedBleed.enabled,.generatedEnabled)).labelsHidden().toggleStyle(.switch).inspectorTarget("generateBleed").help("Eksik taşma payını üretir.")
                let value = model.project.binding == .gang ? Binding(get:{ model.workflowBleed },set:{ model.workflowBleed = $0 }) : guide(\.bleed,field:.bleed,overlay:\.bleed)
                DimensionInput("Taşma payı",value:Binding(get:{ value.wrappedValue },set:{ model.markManual(.bleed); model.workflowBleed = $0 }),range:0...30,inspectorID:"bleed")
            }
            ForEach(Array(model.bleedResultLines.enumerated()),id:\.offset) { _,line in Text(line).font(.system(size:12)).foregroundStyle(DesignSystem.muted).fixedSize(horizontal:false,vertical:true) }
            if model.showsMissingBleedWarning {
                HStack {
                    Label(Workspace.missingBleedWarning,systemImage:"exclamationmark.triangle.fill").font(.system(size:12))
                    Button("Taşmayı aç") { model.enableMissingBleed() }
                }.padding(8).background(DesignSystem.warning.opacity(0.12),in:RoundedRectangle(cornerRadius:8))
            }

        }
    }
    private var methodControls: some View {
        Picker("Yöntem",selection: Binding(get: { model.project.binding },set: model.setMode)) {
            Text("Tekrarlı (kartvizit/düz iş)").tag(BindingMethod.stepAndRepeat)
            Text("Karışık iş (gang)").tag(BindingMethod.gang)
            Text("Tel dikiş").tag(BindingMethod.saddleStitch)
            Text("Tutkallı cilt").tag(BindingMethod.perfectBound)
            Text("Dikişli cilt").tag(BindingMethod.sewn)
            Text("Spiral").tag(BindingMethod.spiral)
            Text("Wire-O").tag(BindingMethod.wireO)
        }.inspectorTarget("method").inspectorSetting(model,"Yöntem",SettingGuidance.detail("Yöntem"))
    }

    private var signatureControls: some View {
        Picker("Forma",selection: $model.project.settings.signatureSize) {
            Text("Otomatik").tag(SignatureSize.automatic)
            Text("4 sayfa (tek kat)").tag(SignatureSize.four)
            Text("8 sayfa").tag(SignatureSize.eight)
            Text("16 sayfa").tag(SignatureSize.sixteen)
            Text("32 sayfa").tag(SignatureSize.thirtyTwo)
        }.inspectorTarget("signature").inspectorSetting(model,"Forma",SettingGuidance.detail("Forma"))
    }

    private var sheetControls: some View {
        VStack(spacing: 10) {
            Picker("Tabaka seçimi",selection: Binding(get: { model.project.autoLayout?.sheetSelection ?? .fixed },set: model.setSheetSelection)) {
                Text("Sabit").tag(SheetSelection.fixed)
                Text("En verimli").tag(SheetSelection.efficient)
                Text("Otomatik").tag(SheetSelection.automatic)
            }.pickerStyle(.segmented).inspectorTarget("sheetSelection").inspectorSetting(model,"Tabaka seçimi",SettingGuidance.detail("Tabaka seçimi"))
        }
    }
    private var edgeControls: some View {
        VStack(spacing: 10) {
            measurement("Sol",$model.project.sheet.margins.left,autoField: .marginLeft,id:"leftMargin")
            measurement("Sağ",$model.project.sheet.margins.right,autoField: .marginRight,id:"rightMargin")
            measurement("Üst",$model.project.sheet.margins.top,autoField: .marginTop,id:"topMargin")
            measurement("Alt",$model.project.sheet.margins.bottom,autoField: .marginBottom,id:"bottomMargin")
            Text("Maşa").font(.headline).frame(maxWidth:.infinity,alignment:.leading)
            Picker("Maşa kenarı",selection: model.autoBinding($model.project.sheet.gripperEdge,.gripperEdge)) {
                Text("Alt").tag(ImpositionCore.Edge.bottom); Text("Üst").tag(ImpositionCore.Edge.top)
                Text("Sol").tag(ImpositionCore.Edge.left); Text("Sağ").tag(ImpositionCore.Edge.right)
            }.inspectorTarget("gripperEdge").automaticReset(model,.gripperEdge)
            measurement("Maşa payı",$model.project.sheet.gripperWidth,autoField: .gripperWidth,id:"gripperWidth")
            Text("Aralıklar").font(.headline).frame(maxWidth:.infinity,alignment:.leading)
            if model.project.isBooklet {
                Text("Kat komşuları: 0 mm (sabit)").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
            } else {
                measurement("Ara boşluk",$model.project.sheet.gutter,autoField: .gutter,id:"gutter")
            }
        }
    }
    private var markControls: some View {
        VStack(spacing: 10) {
            measurement("Kesim uzunluğu",guide(\.cropMarkLength,field: .cropLength,overlay: \.crop),autoField: .cropLength,range: 0...30,id:"cropLength")
            if model.project.settings.cropMarkLength > 0 {
                measurement("Kesim uzaklığı",guide(\.cropMarkOffset,field: .cropOffset,overlay: \.crop),autoField: .cropOffset,range: 0...30,id:"cropOffset")
            }
            Text("Çıktı kesim işareti: "+(model.project.exportMarks.crop ? "Açık" : "Kapalı"))
                .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
            measurement("Güvenli alan",guide(\.safeAreaInset,field: .safeArea,overlay: \.safeArea),autoField: .safeArea,range: 0...30,id:"safeInset")
        }
    }
    private var overlayControls: some View {
        VStack(alignment: .leading,spacing: 8) {
            Toggle("Kesim çizgisi (çıktıya basılmaz)",isOn: $model.overlays.crop).inspectorTarget("previewCrop").inspectorSetting(model,"Kesim işaretleri",SettingGuidance.detail("Kesim işaretleri"))
            if model.project.isLeafBinding { Toggle("Delik kılavuzları (çıktıya basılmaz)",isOn:$model.overlays.punch).inspectorTarget("previewPunch").inspectorSetting(model,"Delik kılavuzları",SettingGuidance.detail("Delik kılavuzları")) }
            if model.project.binding != .stepAndRepeat && model.project.binding != .gang { Toggle("Katlama kılavuzu (çıktıya basılmaz)",isOn: $model.overlays.fold).inspectorTarget("previewFold").inspectorSetting(model,"Katlama çizgileri",SettingGuidance.detail("Katlama çizgileri")) }
            Toggle("Taşma kılavuzu (çıktıya basılmaz)",isOn: $model.overlays.bleed).inspectorTarget("previewBleed").inspectorSetting(model,"Taşma çizgileri",SettingGuidance.detail("Taşma çizgileri"))
            Toggle("Güvenli alan (çıktıya basılmaz)",isOn: $model.overlays.safeArea).inspectorTarget("previewSafe").inspectorSetting(model,"Güvenli alan",SettingGuidance.detail("Güvenli alan"))
            Toggle("Sayfa numaraları (çıktıya basılmaz)",isOn: $model.overlays.pageNumbers).inspectorTarget("previewNumbers").inspectorSetting(model,"Sayfa numaraları",SettingGuidance.detail("Sayfa numaraları"))
            Toggle("Tabaka sınırı (çıktıya basılmaz)",isOn: $model.overlays.sheetBoundary).inspectorTarget("previewSheet").inspectorSetting(model,"Tabaka sınırı",SettingGuidance.detail("Tabaka sınırı"))
            Toggle("Kenar payı / maşa (çıktıya basılmaz)",isOn: $model.overlays.pressGuides).inspectorTarget("previewGripper").inspectorSetting(model,"Kenar payı / maşa",SettingGuidance.detail("Kenar payı / maşa"))
        }.toggleStyle(.switch).frame(maxWidth: .infinity,alignment: .leading)
    }
    private var previewColorControl: some View {
        Toggle("Renk skalası kılavuzu (çıktıya basılmaz)",isOn: Binding(get: { model.overlays.colorBar },set: model.setPreviewColorBar)).inspectorTarget("previewColor").inspectorSetting(model,"Renk skalası",SettingGuidance.detail("Renk skalası"))
            .toggleStyle(.switch)
    }
    private var previewRegistrationControl: some View {
        Toggle("Diz kılavuzları (çıktıya basılmaz)",isOn: Binding(get: { model.overlays.registrationTargets },set: model.setPreviewTargets)).inspectorTarget("previewTargets").inspectorSetting(model,"Diz işaretleri",SettingGuidance.detail("Diz işaretleri"))
            .toggleStyle(.switch)
    }
    private func guide(_ key: WritableKeyPath<ImpositionSettings,Double>,field: AutoLayoutField,overlay: WritableKeyPath<PreviewOverlays,Bool>) -> Binding<Double> {
        model.guideDimensionBinding(key,field:field)
    }
    private var generatedBleedControls: some View {
        VStack(alignment: .leading,spacing: 9) {
            if (model.selectedGangJob?.bleed ?? model.project.settings.bleed) > 0 {
                if model.editableGeneratedBleed.enabled {
                    Picker("Yöntem",selection: model.autoBinding($model.editableGeneratedBleed.method,.generatedMethod)) {
                        Text("Otomatik").tag(GeneratedBleedMethod.automatic)
                        Text("Yansıt").tag(GeneratedBleedMethod.mirror)
                        Text("Renk").tag(GeneratedBleedMethod.solidColor)
                    }.pickerStyle(.segmented).inspectorTarget("bleedMethod").automaticReset(model,.generatedMethod)
                    if model.editableGeneratedBleed.method == .automatic {
                        Text("Kesim kenarları vektör olarak yansıtılır.").font(.system(size:12)).foregroundStyle(DesignSystem.muted)
                    }
                    if model.editableGeneratedBleed.method == .solidColor {
                        Picker("Renk uzayı",selection: Binding(get: { model.editableGeneratedBleed.color.components.count == 4 },
                            set: { model.markManual(.generatedColor); model.editableGeneratedBleed.color = $0 ? .cmyk(0,0,0,0) : .rgb(1,1,1) })) {
                            Text("CMYK").tag(true); Text("RGB").tag(false)
                        }.pickerStyle(.segmented).automaticReset(model,.generatedColor)
                        let names = model.editableGeneratedBleed.color.components.count == 4 ? ["C","M","Y","K"] : ["R","G","B"]
                        ForEach(Array(names.enumerated()),id: \.offset) { index,name in
                            measurement(name+" (%)",colorComponent(index),autoField: .generatedColor,range: 0...100)
                        }
                    }
                    if let summary = model.bleedSampleSummary { Text(summary).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1) }
                    Text("Yalnız kesim dışını değiştirir. Sıfır ara boşlukta blok çevresi üretilir.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                }
            } else { Text("Üretim için taşma payını artırın.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1) }
        }
    }
    private func colorComponent(_ index: Int) -> Binding<Double> {
        Binding(get: { model.editableGeneratedBleed.color.components[index]*100 },set: { value in
            var values = model.editableGeneratedBleed.color.components
            values[index] = value/100
            model.editableGeneratedBleed.color = values.count == 4 ?
                .cmyk(values[0],values[1],values[2],values[3]) : .rgb(values[0],values[1],values[2])
        })
    }
    private var repeatControls: some View {
        GroupBox("Tekrarlı Yerleşim") {
            VStack(alignment: .leading,spacing: 10) {
                if !usingMachineProfile {
                    Picker("Dizilim",selection: Binding(get: { model.repeatArrangement },set: model.setRepeatArrangement)) {
                        Text("Bitişik").tag(RepeatArrangement.adjacent)
                        Text("Aralıklı").tag(RepeatArrangement.spaced)
                        Text("Özel").tag(RepeatArrangement.custom)
                    }.pickerStyle(.segmented).inspectorTarget("arrangement").automaticReset(model,.gutter)
                    Text(model.repeatArrangement == .adjacent ? "Ortak kesim; taşma sadece blok çevresinde." : model.repeatArrangement == .spaced ? "Otomatik ara boşluk taşmanın iki katıdır." : "Elle belirlenen ara boşluk korunur.")
                        .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                    Toggle("90° döndürmeye izin ver",isOn: model.autoBinding($model.project.stepAndRepeat.allowRotation,.allowRotation)).inspectorTarget("rotate").automaticReset(model,.allowRotation)
                }
                if !usingMachineProfile {
                    gridOverride("Sütun",value: $model.project.stepAndRepeat.columns,
                                 automatic: model.currentSheet?.repeatLayout?.columns ?? 1,field: .columns)
                    gridOverride("Satır",value: $model.project.stepAndRepeat.rows,
                                 automatic: model.currentSheet?.repeatLayout?.rows ?? 1,field: .rows)
                }
                if let sheet = model.currentSheet, let layout = sheet.repeatLayout {
                    Text("\(layout.columns) × \(layout.rows) = \(layout.copiesPerSheet) adet/tabaka").fontWeight(.medium)
                    if !usingMachineProfile, model.project.autoLayout?.automaticFields.contains(.allowRotation) == true {
                        Text("Ürün dönüşü: \(sheet.front.slots.first?.rotation ?? 0)° · Otomatik").font(.system(size:12))
                    }
                    Text("Bu iş: \(sheet.repeatCount) tabaka · Üretim: \(sheet.producedQuantityDescription) adet")
                    Text("Tüm işler: \(model.plan.totalPressSheets) tabaka")
                }
                if !usingMachineProfile {
                    Text(model.project.sheet.gutter == 0 ? "Bitişik dizilimde taşma yoktur, kesim çizgisinde kırpılır" : "Ara boşluk, komşu taşma kutuları arasında ölçülür.")
                        .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                }
                if usingMachineProfile ? model.project.machineProfile?.faces == .workAndTurn : model.project.settings.turnMethod != .sheetwise {
                    Text("Aynı kalıp iki yüzde kullanılır. Çevirme eksenindeki ürün sayısı çift olmalıdır.")
                        .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                }
            }.toggleStyle(.switch).padding(5)
        }
    }
    private func gridOverride(_ title: String,value: Binding<Int?>,automatic: Int,field: AutoLayoutField) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            Toggle("\(title) sayısını belirle",isOn: model.optionalCountBinding(value,name:field.rawValue,defaultValue:min(200,automatic),field:field)).inspectorTarget(field.rawValue).automaticReset(model,field)
            if value.wrappedValue != nil {
                Stepper("\(title): \(value.wrappedValue ?? 1)",value: Binding(get: { value.wrappedValue ?? 1 },
                    set: { model.markManual(field); value.wrappedValue = $0 }),in: 1...200)
            }
        }
    }
    private func measurement(_ title: String, _ value: Binding<Double>,autoField: AutoLayoutField? = nil, range: ClosedRange<Double> = 0...200, id: String? = nil) -> some View {
        let effective = autoField.map { model.autoBinding(value,$0) } ?? value
        let measurementID = id ?? title
        return VStack(alignment:.leading,spacing:DesignSystem.Space.xs) {
            HStack(spacing:DesignSystem.Space.sm) {
                Text(title.replacingOccurrences(of:" (%)",with:"")).frame(maxWidth:.infinity,alignment:.leading)
                DimensionInput(title,value:effective,unit:title.contains("%") ? "%" : "mm",range:range,inspectorID:id) { focused in
                    if focused {
                        focusedMeasurement = measurementID
                        model.ui.focusedArea = autoField.flatMap(WorkflowPresentation.focus)
                    } else if focusedMeasurement == measurementID {
                        focusedMeasurement = nil
                        model.ui.focusedArea = nil
                    }
                }
            }
        }.simultaneousGesture(TapGesture().onEnded { model.ui.focusedArea = autoField.flatMap(WorkflowPresentation.focus) })
            .inspectorSetting(model,title,autoField.map(SettingGuidance.detail) ?? "Ölçülmüş değeri girin. Birim: alan etiketindeki mm veya yüzde. Örnek: değişiklik mevcut önizlemeye yansır.")
    }
}

/// Shared workflow control, presented in the preview toolbar rather than details.
struct PreviewScopePicker:View {
    @ObservedObject var model:Workspace
    var body:some View {
        Picker("Görünüm",selection:Binding(get:{ model.project.allSheetsPreview ?? model.showsAllSides },set:{ model.showsAllSides = $0 })) {
            Text("Tüm yüzler").tag(true); Text("Tek yüz").tag(false)
        }.pickerStyle(.segmented).frame(maxWidth:240)
    }
}


private struct ToneControls: View {
    @ObservedObject var model: Workspace
    @State private var pageScope = false
    @State private var chosenPage: Int?
    @State private var face: SideKind = .front

    private var pages: [Int] { model.source?.pages.map(\.number) ?? [] }
    private var selectedSourcePage: Int? {
        guard model.selectedPages.count == 1, let selection = model.selectedPages.first else { return nil }
        if let items = model.project.pageItems { return items.first { $0.id == selection }?.sourcePage }
        return selection
    }
    private var page: Int? {
        [chosenPage,selectedSourcePage,model.currentSide?.slots.compactMap(\.sourcePageNumber).first,pages.first]
            .compactMap { $0 }.first { pages.contains($0) }
    }
    private var amount: Binding<Int> {
        Binding(get: {
            let tone = model.project.settings.tone ?? ArtworkTone()
            if pageScope, let page { return tone.value(forPage: page,side: face) }
            return ArtworkTone.clamped(tone.job[face] ?? 0)
        },set: { update($0) })
    }
    private func update(_ value: Int?) {
        guard !pageScope || page != nil else { return }
        var tone = model.project.settings.tone ?? ArtworkTone()
        tone.set(value,page: pageScope ? page : nil,side: face)
        model.project.settings.tone = tone == ArtworkTone() ? nil : tone
    }
    private func showPage() {
        guard pageScope, let page else {
            if !pageScope { model.side = face }
            return
        }
        for (index,sheet) in model.displaySheets.enumerated() {
            for (side, slots) in [(SideKind.front,sheet.front.slots),(.back,sheet.back.slots)] {
                if slots.contains(where: { $0.sourcePageNumber == page && ($0.itemSide ?? side) == face }) {
                    model.sheetIndex = index
                    model.side = side
                    return
                }
            }
        }
    }
    var body: some View {
        Picker("Kapsam",selection: $pageScope) {
            Text("Tüm iş").tag(false)
            Text("Seçili sayfa").tag(true)
        }.pickerStyle(.segmented)
        if pageScope {
            Picker("PDF sayfası",selection: Binding(get: { page },set: { chosenPage = $0; showPage() })) {
                if pages.isEmpty { Text("Sayfa yok").tag(Int?.none) }
                ForEach(pages,id: \.self) { Text("Sayfa \($0)").tag(Optional($0)) }
            }
        }
        Picker("Yüz",selection: $face) {
            Text("Ön").tag(SideKind.front)
            Text("Arka").tag(SideKind.back)
        }.pickerStyle(.segmented)
            .onChange(of: face) { _, _ in showPage() }
        HStack {
            Slider(value: Binding(get: { Double(amount.wrappedValue) },set: { amount.wrappedValue = Int($0) }),
                   in: -50...50,step: 1) { Text("Ton") }
                .accessibilityLabel("Ton")
            TextField("Ton değeri",value: amount,format: .number)
                .multilineTextAlignment(.trailing).frame(width: 58)
                .accessibilityLabel("Ton değeri")
                .inspectorTarget("artworkTone")
        }.disabled(pageScope && page == nil)
        HStack {
            Button("Sıfırla") { update(0) }
            if pageScope, let page, model.project.settings.tone?.pages[page]?[face] != nil {
                Button("İş tonunu kullan") { update(nil) }
            }
        }.disabled(pageScope && page == nil)
        .onChange(of: model.selectedPages) { _, _ in chosenPage = nil }
        .onChange(of: model.source?.id) { _, _ in chosenPage = nil }
        .onAppear { face = model.side }
        .help("Varsayılan iş tonu, sayfaya özel değer girildiğinde o yüz için geçersiz kılınır.")
    }
}
