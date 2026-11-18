import SwiftUI
import AppKit
import ImpositionCore

struct InspectorView: View {
    @ObservedObject var model: Workspace
    @ObservedObject var prices:PricingStore
    @FocusState private var focusedField:AutoLayoutField?
    var only:InspectorPanel? = nil
    @State private var group=0
    init(model:Workspace,prices:PricingStore,only:InspectorPanel? = nil,group:Int = 0) {
        self.model=model;self.prices=prices;self.only=only;_group=State(initialValue:group)
    }
    private var panel:InspectorPanel {only ?? model.ui.activePanel}
    private var groups:[String] {panel.groups(for:model.project)}
    private var manualFields:[AutoLayoutField] {
        InspectorRegistry.fields(panel).filter {model.isManual($0) || model.project.autoLayout?.presetFields?.contains($0)==true}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Label(panel.title,systemImage:panel.symbol).font(.system(size:17,weight:.semibold))
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("panel.header."+panel.rawValue)
            Button("\(manualFields.count) ayar manuel · Otomatiğe döndür") {model.returnToAutomatic(manualFields)}
                .buttonStyle(.link).disabled(manualFields.isEmpty).font(.system(size:12))
            if groups.count>1 {
                Picker("Alt grup",selection:$group) {
                    ForEach(Array(groups.enumerated()),id:\.offset) {index,title in Text(title).tag(index)}
                }.frame(minHeight:30).accessibilityLabel(panel.title+" alt grubu")
            }
            ViewThatFits(in:.vertical) {
                content.fixedSize(horizontal:false,vertical:true)
                ScrollView {content}.accessibilityIdentifier("panel.localScroll")
            }
            Spacer(minLength:0)
        }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .font(.system(size:13)).controlSize(.large)
            .background(DesignSystem.card).environmentObject(model).tint(DesignSystem.teal)
            .accessibilityElement(children:.contain).accessibilityLabel(panel.title+" paneli")
            .accessibilityIdentifier("panel."+panel.rawValue)
            .disabled(model.loading || model.preparingSource || model.autoArranging)
            .onChange(of:panel) {_,_ in group=0}
            .onChange(of:model.project.binding) {_,_ in group=0}
            .onChange(of:model.ui.revealedSection) {_,section in
                guard let section else {return}
                if section == .edges {model.ui.detailsExpanded=true}
                if section == .serial {model.ui.expandedAddons.insert(.serial)}
                if section == .price {model.ui.expandedAddons.insert(.pricing)}
                model.ui.collapsedCards=[]
                model.ui.jump(InspectorPanel.legacy(section));model.ui.revealedSection=nil
            }
            .onChange(of:focusedField) {_,field in model.ui.focusedArea=field.flatMap(WorkflowPresentation.focus)}
            .task {model.refreshWorkflowRecommendation()}
            .onChange(of:model.project) {_,_ in model.refreshWorkflowRecommendation()}
    }
    private var content:some View {
        VStack(alignment:.leading,spacing:12) {sectionContent(panel)}
            .frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func sectionContent(_ panel:InspectorPanel) -> some View {
        switch panel {
        case .job:
            switch group {
            case 1:methodControls
            case 2:
                if model.project.team != nil { TeamInspectorView(model: model) }
                else if model.project.binding == .gang { GangInspectorView(model:model) }
                else {
                    ForEach(Array(model.project.repeatJobs.enumerated()),id:\.offset) {index,job in
                        Picker("İş \(index+1) yüzleri",selection:Binding(get:{model.jobPageLayout(frontPage:job.front.number)},set:{model.setJobPageLayout(frontPage:job.front.number,mode:$0)})) {
                            Text("Genel ayar").tag(PageLayout.automatic);Text("Tek yüz").tag(PageLayout.simplex);Text("Çift yüz").tag(PageLayout.duplex)
                        }
                    }
                }
            case 3:FireControlsView(model:model)
            case 4:PresetInspectorView(model:model)
            default:
                workflowProduct
                if model.project.team != nil { TeamInspectorView(model: model) }
                else if model.canStartTeam { Button("Takım olarak diz", action: model.startTeam) }
                RescaleInspectorView(model:model)
                if model.project.binding == .stepAndRepeat {Toggle("Adet hesapla (her iş için)",isOn:model.optionalCountBinding($model.project.stepAndRepeat.quantity,name:"quantity",defaultValue:1000))}
            }
        case .sheet:
            if group==0 {workflowPaper;sheetControls}
            else if model.project.binding == .stepAndRepeat {repeatControls}
            else {Text("Yerleşim bu işin cilt yöntemine göre hesaplanır.")}
        case .edges:
            edgeControls
            Picker("Hizalama",selection:model.autoBinding($model.project.blockAlignment,.alignment)) {
                Text("Ortala").tag(BlockAlignment.center);Text("Maşaya yasla").tag(BlockAlignment.gripper)
            }.pickerStyle(.segmented).automaticReset(model,.alignment)
        case .bleed:
            if group==0 {workflowBleed} else {generatedBleedControls}
        case .marks:
            switch group {
            case 1:markControls
            case 2:ColorControlSizeView(model:model)
            case 3:ExportMarksView(model:model,inline:true,scope:.info)
            case 4:overlayControls
            default:ExportMarksView(model:model,inline:true,scope:.printed)
            }
        case .serial:SerialInspectorView(model:model,compact:true,section:group)
        case .scaling:
            SourcePageTools(model:model)
            Button("Ebadı değiştir…") {model.openScaleWindow()}.disabled(model.project.pages.isEmpty || model.scalingRows.isEmpty)
            if let prompt=model.rescalePrompt {ScalingSuggestionBanner(model:model,prompt:prompt)}
        case .binding:
            if model.project.isLeafBinding {
                if group==0 {methodControls}
                LeafInspectorView(model:model,section:group)
            }
            else if group==0 {methodControls}
            else if group==4 {BlankPlacementInspector(model:model)}
            else if model.project.isBooklet {BookInspectorView(model:model,section:group-1)}
        case .price:
            if group<4 {CostingView(model:model,store:prices,inline:true,section:group)} else {PricingView(store:prices,inline:true)}
        case .output:
            if group==0 {
                ForEach(ExportPreset.allCases,id:\.self) {preset in
                    Button(preset.rawValue) {model.project.exportMarks=preset.applying(to:model.project.exportMarks)}.frame(minHeight:30)
                }
                ExportMarksView(model:model,inline:true,scope:.options)
                Button("PDF’i Hazırla") {model.preparingExport=true}.disabled(!model.canExportNow)
            } else {PreflightView(model:model)}
        }
    }
    private var workflowProduct:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            Text(model.workflowProductSummary).font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
            Picker("Ürün tipi",selection:Binding(get:{ model.productKind },set:model.setProductKind)) {
                ForEach(ProductKind.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            if model.project.binding == .stepAndRepeat {
                if (model.source?.pages.count ?? model.project.pages.count) > 1 {
                    Picker("Sayfa düzeni",selection: Binding(get: { model.pageLayoutMode },set: model.setPageLayout)) {
                        Text("Otomatik").tag(PageLayout.automatic)
                        Text("Çift yüz").tag(PageLayout.duplex)
                        Text("Tek yüz").tag(PageLayout.simplex)
                    }.pickerStyle(.segmented).inspectorSetting(model,"Sayfa düzeni",SettingGuidance.detail("Sayfa düzeni"))
                }
                Text(model.pageLayoutSummary).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
            }
            HStack(spacing:DesignSystem.Space.sm) {
                Text("Adet").frame(maxWidth:.infinity,alignment:.leading)
                TextField("örn. 1000",value:Binding<Int?>(get:{ model.basicQuantity },set:{ model.basicQuantity = $0 }),format:.number.locale(TRFormat.locale))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Adet").accessibilityIdentifier("setting.quantity").frame(width:72)
                Text("adet").font(.system(size:12)).foregroundStyle(DesignSystem.muted).fixedSize().frame(width:32,alignment:.leading)
                Stepper("Adet",value:Binding(get:{ model.basicQuantity ?? 1 },set:{ model.basicQuantity = $0 }),in:1...100000000).labelsHidden().fixedSize()
            }
            if model.project.isBooklet || model.project.isLeafBinding { Text("Yayın adedi maliyet hesabı içindir; PDF tek yayın planını korur.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1) }
            HStack(spacing:DesignSystem.Space.sm) {
                Text("Fire").help("Ek üretim payı").frame(maxWidth:.infinity,alignment:.leading)
                TextField("0",value:Binding(get:{ model.workflowWastePercent },set:{ model.workflowWastePercent = $0 }),format:.number.locale(TRFormat.locale))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Fire yüzdesi").accessibilityIdentifier("setting.waste.percent").frame(width:72)
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
                }
            }
            OrientationPicker("Yön",selection:Binding(get:{ (model.project.autoLayout ?? .legacy).isFixed(.orientation) ? model.project.sheet.orientation : .auto },set:model.selectWorkflowOrientation)).automaticReset(model,.orientation)


            let selectedSize = model.project.sheet.size
            Text(model.workflowOrientationSummary).help(TRFormat.size(selectedSize.width,selectedSize.height)).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
            if model.showsTurnControl {
                Picker("Ön/arka çevirme",selection:$model.project.settings.turnMethod) {
                    Text("Ayrı kalıp").tag(TurnMethod.sheetwise).help("Ayrı kalıp (sheetwise)")
                    Text("Yandan").tag(TurnMethod.workAndTurn).help("Yandan çevir (work-and-turn)")
                    Text("Baştan").tag(TurnMethod.workAndTumble).help("Baştan çevir (work-and-tumble)")
                }.pickerStyle(.segmented)
                Text(model.turnLabel).font(.system(size:12))
                Text(model.turnHelper).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1).help(model.turnHelper)
            }
            if model.sheetPreset == "Özel" {
                measurement("Genişlik",$model.project.sheet.size.width,autoField:.sheetSize,range:20...3000)
                measurement("Yükseklik",$model.project.sheet.size.height,autoField:.sheetSize,range:20...3000)
            }
            if let recommendation = model.visibleWorkflowRecommendation {
                VStack(alignment:.leading,spacing:DesignSystem.Space.sm) {
                    Label(model.workflowRecommendationText(recommendation),systemImage:"info.circle")
                        .font(.system(size:12).weight(.medium))
                    Button { model.returnToAutomaticSheet() } label: { Text("Öneriyi uygula").foregroundStyle(DesignSystem.success) }.buttonStyle(.borderless).font(.system(size:12).weight(.semibold))
                }.padding(DesignSystem.Space.md).frame(maxWidth:.infinity,alignment:.leading)
                    .foregroundStyle(DesignSystem.success).background(DesignSystem.successSurface,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
            }
            Picker("Üretim",selection:Binding(get:{ model.project.autoLayout?.production ?? .digital },set:model.setProduction)) {
                Text("Dijital").tag(ProductionType.digital); Text("Ofset").tag(ProductionType.offset)
            }.pickerStyle(.segmented)

        }
    }
    private var workflowBleed:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            HStack(spacing:8) {
                Text("Taşma payı").frame(maxWidth:.infinity,alignment:.leading)
                Toggle("Eksik taşmayı üret",isOn:model.autoBinding($model.editableGeneratedBleed.enabled,.generatedEnabled)).labelsHidden().toggleStyle(.switch).help("Eksik taşma payını üretir.")
                let value = model.project.binding == .gang ? Binding(get:{ model.workflowBleed },set:{ model.workflowBleed = $0 }) : guide(\.bleed,field:.bleed,overlay:\.bleed)
                DimensionInput("Taşma payı",value:Binding(get:{ value.wrappedValue },set:{ model.markManual(.bleed); model.workflowBleed = $0 }),range:0...30,enabled:model.editableGeneratedBleed.enabled)
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
        GroupBox("Yerleşim Yöntemi") {
                    VStack(alignment: .leading,spacing: 10) {
                        Picker("Yöntem",selection: Binding(get: { model.project.binding },set: model.setMode)) {
                            Text("Tekrarlı (kartvizit/düz iş)").tag(BindingMethod.stepAndRepeat)
                            Text("Karışık iş (gang)").tag(BindingMethod.gang)
                            Text("Tel dikiş").tag(BindingMethod.saddleStitch)
                            Text("Tutkallı cilt").tag(BindingMethod.perfectBound)
                            Text("Dikişli cilt").tag(BindingMethod.sewn)
                            Text("Spiral").tag(BindingMethod.spiral)
                            Text("Wire-O").tag(BindingMethod.wireO)
                        }.inspectorSetting(model,"Yöntem",SettingGuidance.detail("Yöntem"))
                        if model.project.binding == .perfectBound || model.project.binding == .sewn {
                            Picker("Forma",selection: $model.project.settings.signatureSize) {
                                Text("Otomatik").tag(SignatureSize.automatic)
                                Text("4 sayfa (tek kat)").tag(SignatureSize.four)
                                Text("8 sayfa").tag(SignatureSize.eight)
                                Text("16 sayfa").tag(SignatureSize.sixteen)
                                Text("32 sayfa").tag(SignatureSize.thirtyTwo)
                            }.inspectorSetting(model,"Forma",SettingGuidance.detail("Forma"))
                        }
                    }.padding(5)
                }
    }
    private var sheetControls: some View {
        GroupBox("Baskı Tabakası") {
                    VStack(spacing: 10) {
                        Picker("Tabaka seçimi",selection: Binding(get: { model.project.autoLayout?.sheetSelection ?? .fixed },set: model.setSheetSelection)) {
                            Text("Sabit").tag(SheetSelection.fixed)
                            Text("En verimli").tag(SheetSelection.efficient)
                            Text("Otomatik").tag(SheetSelection.automatic)
                        }.pickerStyle(.segmented).inspectorSetting(model,"Tabaka seçimi",SettingGuidance.detail("Tabaka seçimi"))
                    }.padding(5)
                }
    }
    private var edgeControls: some View {
        GroupBox("Kenar Payları ve Maşa") {
                    VStack(spacing: 10) {
                        measurement("Sol",$model.project.sheet.margins.left,autoField: .marginLeft)
                        measurement("Sağ",$model.project.sheet.margins.right,autoField: .marginRight)
                        measurement("Üst",$model.project.sheet.margins.top,autoField: .marginTop)
                        measurement("Alt",$model.project.sheet.margins.bottom,autoField: .marginBottom)
                        Text("Maşa").font(.headline).frame(maxWidth:.infinity,alignment:.leading)
                        Picker("Maşa kenarı",selection: model.autoBinding($model.project.sheet.gripperEdge,.gripperEdge)) {
                            Text("Alt").tag(ImpositionCore.Edge.bottom); Text("Üst").tag(ImpositionCore.Edge.top)
                            Text("Sol").tag(ImpositionCore.Edge.left); Text("Sağ").tag(ImpositionCore.Edge.right)
                        }.automaticReset(model,.gripperEdge)
                        measurement("Maşa payı",$model.project.sheet.gripperWidth,autoField: .gripperWidth)
                        Text("Aralıklar").font(.headline).frame(maxWidth:.infinity,alignment:.leading)
                        if model.project.isBooklet {
                            Text("Kat komşuları: 0 mm (sabit)").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                        } else {
                            measurement("Ara boşluk",$model.project.sheet.gutter,autoField: .gutter)
                        }
                    }.padding(5)
                }
    }
    private var markControls: some View {
        GroupBox("Taşma ve İşaretler") {
                    VStack(spacing: 10) {
                        measurement("Kesim uzunluğu",guide(\.cropMarkLength,field: .cropLength,overlay: \.crop),autoField: .cropLength,range: 0...30)
                        if model.project.settings.cropMarkLength > 0 {
                            measurement("Kesim uzaklığı",guide(\.cropMarkOffset,field: .cropOffset,overlay: \.crop),autoField: .cropOffset,range: 0...30)
                        }
                        Text("Çıktı kesim işareti: "+(model.project.exportMarks.crop ? "Açık" : "Kapalı"))
                            .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1).automaticReset(model,.exportCrop)
                        measurement("Güvenli alan",guide(\.safeAreaInset,field: .safeArea,overlay: \.safeArea),autoField: .safeArea,range: 0...30)
                    }.padding(5)
                }
    }
    private var overlayControls: some View {
        GroupBox("Önizleme Katmanları") {
                    VStack(alignment: .leading,spacing: 8) {
                        Toggle("Kesim çizgisi (çıktıya basılmaz)",isOn: $model.overlays.crop).inspectorSetting(model,"Kesim işaretleri",SettingGuidance.detail("Kesim işaretleri"))
                        if model.project.isLeafBinding { Toggle("Delik kılavuzları (çıktıya basılmaz)",isOn:$model.overlays.punch).inspectorSetting(model,"Delik kılavuzları",SettingGuidance.detail("Delik kılavuzları")) }
                        if model.project.binding != .stepAndRepeat && model.project.binding != .gang { Toggle("Katlama kılavuzu (çıktıya basılmaz)",isOn: $model.overlays.fold).inspectorSetting(model,"Katlama çizgileri",SettingGuidance.detail("Katlama çizgileri")) }
                        Toggle("Taşma kılavuzu (çıktıya basılmaz)",isOn: $model.overlays.bleed).inspectorSetting(model,"Taşma çizgileri",SettingGuidance.detail("Taşma çizgileri"))
                        Toggle("Güvenli alan (çıktıya basılmaz)",isOn: $model.overlays.safeArea).inspectorSetting(model,"Güvenli alan",SettingGuidance.detail("Güvenli alan"))
                        Toggle("Sayfa numaraları (çıktıya basılmaz)",isOn: $model.overlays.pageNumbers).inspectorSetting(model,"Sayfa numaraları",SettingGuidance.detail("Sayfa numaraları"))
                        Toggle("Tabaka sınırı (çıktıya basılmaz)",isOn: $model.overlays.sheetBoundary).inspectorSetting(model,"Tabaka sınırı",SettingGuidance.detail("Tabaka sınırı"))
                        Toggle("Kenar payı / maşa (çıktıya basılmaz)",isOn: $model.overlays.pressGuides).inspectorSetting(model,"Kenar payı / maşa",SettingGuidance.detail("Kenar payı / maşa"))
                        Toggle("Renk skalası kılavuzu (çıktıya basılmaz)",isOn: Binding(get: { model.overlays.colorBar },set: model.setPreviewColorBar)).inspectorSetting(model,"Renk skalası",SettingGuidance.detail("Renk skalası"))
                        Toggle("Diz kılavuzları (çıktıya basılmaz)",isOn: Binding(get: { model.overlays.registrationTargets },set: model.setPreviewTargets)).inspectorSetting(model,"Diz işaretleri",SettingGuidance.detail("Diz işaretleri"))
                    }.toggleStyle(.switch).frame(maxWidth: .infinity,alignment: .leading).padding(5)
                }
    }
    private func guide(_ key: WritableKeyPath<ImpositionSettings,Double>,field: AutoLayoutField,overlay: WritableKeyPath<PreviewOverlays,Bool>) -> Binding<Double> {
        model.guideDimensionBinding(key,field:field)
    }
    private var generatedBleedControls: some View {
        GroupBox("Üretilmiş Taşma") {
            VStack(alignment: .leading,spacing: 9) {
                if (model.selectedGangJob?.bleed ?? model.project.settings.bleed) > 0 {
                    if model.editableGeneratedBleed.enabled {
                        Picker("Yöntem",selection: model.autoBinding($model.editableGeneratedBleed.method,.generatedMethod)) {
                            Text("Otomatik").tag(GeneratedBleedMethod.automatic)
                            Text("Yansıt").tag(GeneratedBleedMethod.mirror)
                            Text("Renk").tag(GeneratedBleedMethod.solidColor)
                        }.pickerStyle(.segmented).automaticReset(model,.generatedMethod)
                        if model.editableGeneratedBleed.method == .automatic {
                            measurement("Tolerans (%)",Binding(get: { model.editableGeneratedBleed.tolerance*100 },
                                set: { model.editableGeneratedBleed.tolerance = $0/100 }),autoField: .generatedTolerance,range: 0...100)
                            Text("Tek renk kenar: vektör dolgu. Değişken kenar: kenar piksellerini uzat.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
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
            }.padding(5)
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
                Picker("Dizilim",selection: Binding(get: { model.repeatArrangement },set: model.setRepeatArrangement)) {
                    Text("Bitişik").tag(RepeatArrangement.adjacent)
                    Text("Aralıklı").tag(RepeatArrangement.spaced)
                    Text("Özel").tag(RepeatArrangement.custom)
                }.pickerStyle(.segmented).automaticReset(model,.gutter)
                Text(model.repeatArrangement == .adjacent ? "Ortak kesim; taşma sadece blok çevresinde." : model.repeatArrangement == .spaced ? "Otomatik ara boşluk taşmanın iki katıdır." : "Elle belirlenen ara boşluk korunur.")
                    .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                Toggle("90° döndürmeye izin ver",isOn: model.autoBinding($model.project.stepAndRepeat.allowRotation,.allowRotation)).automaticReset(model,.allowRotation)
                gridOverride("Sütun",value: $model.project.stepAndRepeat.columns,
                             automatic: model.currentSheet?.repeatLayout?.columns ?? 1,field: .columns)
                gridOverride("Satır",value: $model.project.stepAndRepeat.rows,
                             automatic: model.currentSheet?.repeatLayout?.rows ?? 1,field: .rows)
                if let sheet = model.currentSheet, let layout = sheet.repeatLayout {
                    Text("\(layout.columns) × \(layout.rows) = \(layout.copiesPerSheet) adet/tabaka").fontWeight(.medium)
                    if model.project.autoLayout?.automaticFields.contains(.allowRotation) == true {
                        Text("Ürün dönüşü: \(sheet.front.slots.first?.rotation ?? 0)° · Otomatik").font(.system(size:12))
                    }
                    Text("Bu iş: \(sheet.repeatCount) tabaka · Üretim: \(sheet.producedQuantityDescription) adet")
                    Text("Tüm işler: \(model.plan.totalPressSheets) tabaka")
                }
                Text(model.project.sheet.gutter == 0 ? "Bitişik dizilimde taşma yoktur, kesim çizgisinde kırpılır" : "Ara boşluk, komşu taşma kutuları arasında ölçülür.")
                    .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                if model.project.settings.turnMethod != .sheetwise {
                    Text("Aynı kalıp iki yüzde kullanılır. Çevirme eksenindeki ürün sayısı çift olmalıdır.")
                        .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                }
            }.toggleStyle(.switch).padding(5)
        }
    }
    private func gridOverride(_ title: String,value: Binding<Int?>,automatic: Int,field: AutoLayoutField) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            Toggle("\(title) sayısını belirle",isOn: model.optionalCountBinding(value,name:field.rawValue,defaultValue:min(200,automatic),field:field)).automaticReset(model,field)
            if value.wrappedValue != nil {
                Stepper("\(title): \(value.wrappedValue ?? 1)",value: Binding(get: { value.wrappedValue ?? 1 },
                    set: { model.markManual(field); value.wrappedValue = $0 }),in: 1...200)
            }
        }
    }
    private func measurement(_ title: String, _ value: Binding<Double>,autoField: AutoLayoutField? = nil, range: ClosedRange<Double> = 0...200) -> some View {
        let effective = autoField.map { model.autoBinding(value,$0) } ?? value
        return VStack(alignment:.leading,spacing:DesignSystem.Space.xs) {
            HStack(spacing:DesignSystem.Space.sm) {
                Text(title.replacingOccurrences(of:" (%)",with:"")).frame(maxWidth:.infinity,alignment:.leading)
                DimensionInput(title,value:effective,unit:title.contains("%") ? "%" : "mm",range:range)
                    .focused($focusedField,equals:autoField)
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
