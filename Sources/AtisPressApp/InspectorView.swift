import SwiftUI
import ImpositionCore

struct InspectorView: View {
    @ObservedObject var model: Workspace
    private let presets: [String:SheetPreset] = ["A5":.a5,"A4":.a4,"A3":.a3,"SRA3":.sra3,"33×48":.cm33x48,
        "35×50":.cm35x50,"50×70":.cm50x70,"70×100":.cm70x100]
    private var presetBinding: Binding<String> {
        Binding(get: { model.sheetPreset },set: { value in
            if value == Workspace.automaticSheetTitle { model.returnToAutomaticSheet(); return }
            model.markManual(.sheetSize)
            model.sheetPreset = value
            if let selected = presets[value] { model.project.sheet.size = selected.size }
        })
    }
    @ObservedObject var prices:PricingStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField:AutoLayoutField?
    private var bindingCardVisible:Bool { WorkflowPresentation.showsBindingCard(model.productKind) }
    var body:some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment:.leading,spacing:DesignSystem.Space.lg) {
                    Text("Ayarlar").font(.title2.bold()).padding(.top,DesignSystem.Space.xs)
                    WorkflowCard(1,"Ne basıyoruz?") { workflowProduct }.id(InspectorSection.product)
                    WorkflowCard(2,"Hangi kâğıda basılacak?") { workflowPaper }.id(InspectorSection.sheet)
                    if bindingCardVisible { WorkflowCard("Cilt ve kapak") { bindingSettings }.id(InspectorSection.binding) }
                    WorkflowCard(3,"Kesim ve taşma") { workflowCut }.id(InspectorSection.marks)
                    WorkflowCard("Eklemek istersen") {
                        ForEach(WorkflowAddon.allCases) { addon in
                            addonRow(addon)
                            if addon != WorkflowAddon.allCases.last { Divider() }
                        }
                    }
                    WorkflowCard(nil,"Ayrıntılar") {
                        DisclosureGroup("Kenar payı, maşa ve diğer ayrıntılar",isExpanded:Binding(get:{ model.ui.detailsExpanded },set:{ model.ui.detailsExpanded = $0 })) {
                            workflowDetails.padding(.top,DesignSystem.Space.md)
                        }.font(.headline)
                    }.id(InspectorSection.edges)
                }.padding(DesignSystem.Space.lg)
                    .animation(reduceMotion ? nil : .easeInOut(duration:0.16),value:model.ui.expandedAddons)
                    .animation(reduceMotion ? nil : .easeInOut(duration:0.16),value:model.ui.detailsExpanded)
            }.background(DesignSystem.workspace)
                .onChange(of:model.ui.revealedSection) { _,section in
                    guard let section else { return }
                    let target:InspectorSection
                    switch section {
                    case .serial: model.ui.expandedAddons.insert(.serial); target = .serial
                    case .price: model.ui.expandedAddons.insert(.pricing); target = .price
                    case .binding: if !bindingCardVisible { model.ui.detailsExpanded = true }; target = bindingCardVisible ? .binding : .edges
                    case .edges: model.ui.detailsExpanded = true; target = .edges
                    default: target = section
                    }
                    if reduceMotion { scroll.scrollTo(target,anchor:.top) }
                    else { withAnimation(.easeInOut(duration:0.16)) { scroll.scrollTo(target,anchor:.top) } }
                    model.ui.revealedSection = nil
                }
        }.tint(DesignSystem.teal).disabled(model.loading || model.autoArranging)
            .onChange(of:focusedField) { _,field in model.ui.focusedArea = field.flatMap(WorkflowPresentation.focus) }
            .task { model.refreshWorkflowRecommendation() }
            .onChange(of:model.project) { _,_ in model.refreshWorkflowRecommendation() }
    }
    private var workflowProduct:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            Text(model.workflowProductSummary).font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
            Picker("Ürün tipi",selection:Binding(get:{ model.productKind },set:model.setProductKind)) {
                ForEach(ProductKind.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Text("PDF ölçüsü ve mevcut yöntemden otomatik algılandı. Ürün tipini değiştirebilirsiniz.").font(.caption).foregroundStyle(DesignSystem.muted)
            HStack(spacing:DesignSystem.Space.sm) {
                Text("Adet").frame(width:48,alignment:.leading)
                TextField("örn. 1000",value:Binding<Int?>(get:{ model.basicQuantity },set:{ model.basicQuantity = $0 }),format:.number)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Adet").accessibilityIdentifier("setting.quantity")
                Text("adet").font(.callout).foregroundStyle(DesignSystem.muted)
            }
            if model.project.isBooklet || model.project.isLeafBinding { Text("Yayın adedi maliyet hesabı içindir; PDF tek yayın planını korur.").font(.caption).foregroundStyle(DesignSystem.muted) }
            HStack(spacing:DesignSystem.Space.sm) {
                Text("Fire").frame(width:48,alignment:.leading)
                TextField("0",value:Binding(get:{ model.workflowWaste.percent },set:{ value in var waste = model.workflowWaste; waste.percent = value; waste.mode = .percent; model.workflowWaste = waste }),format:.number)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Fire yüzdesi").accessibilityIdentifier("setting.waste.percent")
                Text("%").foregroundStyle(DesignSystem.muted)
            }
            Text(model.workflowWaste.mode == .fixed ? "Sabit adet fire korunuyor; yüzde girerseniz yüzde hesabına geçilir." : "İstenen adede eklenir; üretim yukarı yuvarlanır.").font(.caption).foregroundStyle(DesignSystem.muted)
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
            if model.sheetPreset == "Özel" {
                measurement("Genişlik",$model.project.sheet.size.width,autoField:.sheetSize,range:20...3000)
                measurement("Yükseklik",$model.project.sheet.size.height,autoField:.sheetSize,range:20...3000)
            }
            AutomaticPill(model:model,field:.sheetSize)
            if let recommendation = model.workflowRecommendation {
                VStack(alignment:.leading,spacing:DesignSystem.Space.sm) {
                    Label("Önerilen: \(recommendation.name) · tabakada \(recommendation.copies) adet",systemImage:"checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                    Button { model.returnToAutomaticSheet() } label: { Text("Öneriyi uygula").foregroundStyle(DesignSystem.success) }.buttonStyle(.borderless).font(.caption.weight(.semibold))
                }.padding(DesignSystem.Space.md).frame(maxWidth:.infinity,alignment:.leading)
                    .foregroundStyle(DesignSystem.success).background(DesignSystem.successSurface,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
            }
            Picker("Üretim",selection:Binding(get:{ model.project.autoLayout?.production ?? .digital },set:model.setProduction)) {
                Text("Dijital").tag(ProductionType.digital); Text("Ofset").tag(ProductionType.offset)
            }.pickerStyle(.segmented)
            Text("Otomatik tabaka, mevcut üretim yöntemine ve korunmuş ayarlara göre seçilir.").font(.caption).foregroundStyle(DesignSystem.muted)
        }
    }
    private var workflowCut:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            Toggle("Taşma üret",isOn:model.autoBinding($model.editableGeneratedBleed.enabled,.generatedEnabled)).automaticReset(model,.generatedEnabled)
            measurement("Taşma",Binding(get:{ model.workflowBleed },set:{ model.workflowBleed = $0 }),autoField:model.project.binding == .gang ? nil : .bleed,range:0...30)
            Toggle("Kesim işaretleri",isOn:model.autoBinding($model.project.exportMarks.crop,.exportCrop)).automaticReset(model,.exportCrop)
            if !model.project.isBooklet {
                Picker("Dizilim",selection:Binding(get:{ model.repeatArrangement },set:model.setRepeatArrangement)) {
                    Text("Bitişik").tag(RepeatArrangement.adjacent); Text("Aralıklı").tag(RepeatArrangement.spaced)
                    if model.repeatArrangement == .custom { Text("Özel").tag(RepeatArrangement.custom) }
                }.pickerStyle(.segmented)
            }
            Text(model.project.isBooklet ? "Kitap katlarında ara boşluk 0 mm kalır." : "Bitişik: ortak kesim. Aralıklı: ara boşluk taşmanın iki katıdır.").font(.caption).foregroundStyle(DesignSystem.muted)
        }
    }
    private var bindingSettings:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            methodControls
            if model.project.isLeafBinding { LeafInspectorView(model:model) }
            if model.project.isBooklet { BookInspectorView(model:model); BlankPlacementInspector(model:model) }
        }
    }
    private func addonRow(_ addon:WorkflowAddon) -> some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            Toggle(isOn:Binding(get:{ model.ui.expandedAddons.contains(addon) },set:{ open in if open { model.ui.expandedAddons.insert(addon) } else { model.ui.expandedAddons.remove(addon) } })) {
                VStack(alignment:.leading,spacing:DesignSystem.Space.xs) {
                    Text(addon.rawValue).font(.callout.weight(.medium))
                    if let summary = model.workflowAddonSummary(addon) { Text(summary).font(.caption).foregroundStyle(DesignSystem.muted) }
                }
            }.toggleStyle(.switch).accessibilityLabel(addon.rawValue+" ayarlarını göster")
            if model.ui.expandedAddons.contains(addon) {
                switch addon {
                case .serial: SerialInspectorView(model:model)
                case .scaling: RescaleInspectorView(model:model)
                case .color:
                    Toggle("Renk skalası",isOn:model.autoBinding($model.project.exportMarks.colorBar,.exportColorBar)).automaticReset(model,.exportColorBar)
                    Toggle("Diz işaretleri",isOn:model.autoBinding($model.project.exportMarks.registrationTargets,.exportTargets)).automaticReset(model,.exportTargets)
                    ColorControlSizeView(model:model)
                case .info: SheetInfoInspectorView(model:model)
                case .pricing:
                    CostingView(model:model,store:prices,inline:true)
                    DisclosureGroup("Fiyat kitaplığı") { PricingView(store:prices,inline:true) }
                }
                Text("Ayrıntıları kapatmak yapılandırılmış ayarları silmez.").font(.caption).foregroundStyle(DesignSystem.muted)
            }
        }.id(addon == .serial ? AnyHashable(InspectorSection.serial) : addon == .pricing ? AnyHashable(InspectorSection.price) : AnyHashable(addon))
    }
    private var workflowDetails:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.lg) {
            if !bindingCardVisible { bindingSettings }
            sheetControls
            edgeControls
            Picker("Hizalama",selection:model.autoBinding($model.project.blockAlignment,.alignment)) {
                Text("Ortala").tag(BlockAlignment.center); Text("Maşa kenarına yasla").tag(BlockAlignment.gripper)
            }.automaticReset(model,.alignment)
            markControls
            generatedBleedControls
            if model.project.binding == .stepAndRepeat { repeatControls }
            if model.project.binding == .gang { GangInspectorView(model:model) }
            if model.project.binding == .stepAndRepeat {
                GroupBox("İşlere göre ön / arka") {
                    VStack {
                        ForEach(Array(model.project.repeatJobs.enumerated()),id:\.offset) { index,job in
                            Picker("İş \(index+1) yüzleri",selection:Binding(get:{ model.jobPageLayout(frontPage:job.front.number) },set:{ model.setJobPageLayout(frontPage:job.front.number,mode:$0) })) {
                                Text("Genel ayar").tag(PageLayout.automatic); Text("Tek yüz").tag(PageLayout.simplex); Text("Çift yüz").tag(PageLayout.duplex)
                            }
                        }
                    }
                }
            }
            Picker("Önizleme kapsamı",selection:Binding(get:{ model.project.allSheetsPreview ?? false },set:{ model.project.allSheetsPreview = $0 })) {
                Text("Tek tabaka").tag(false); Text("Tüm tabakalar").tag(true)
            }
            ExportMarksView(model:model,inline:true)
            overlayControls
            PresetInspectorView(model:model)
            PreflightView(model:model)
            Button("Yerleşim alanlarını otomatiğe döndür") { model.requestAutomaticLayout() }
        }.font(.body)
    }
    private var productControls: some View {
        VStack(alignment:.leading,spacing:4) {
            Picker("Ürün tipi",selection:Binding(get:{ model.productKind },set:model.setProductKind)) {
                ForEach(ProductKind.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Text("PDF önerisi: \(ProductKind.detect(model.project).rawValue) · ölçü ve mevcut ciltlemeye göre").font(.caption).foregroundStyle(DesignSystem.muted)
        }.inspectorSetting(model,"Ürün tipi","Üretim yöntemini seçer. Kartvizit/Form tekrarlı, Broşür tel dikiş, Kitap tutkallı cilt, Spiral yaprak cilt kullanır. Örnek: Broşür seçimi mevcut tel dikiş yöntemini açar. PDF içeriğinin anlamı otomatik okunmaz.",keywords:"kartvizit broşür form kitap spiral")
    }
    private var productionControls: some View {
        Picker("Üretim",selection:Binding(get:{ model.project.autoLayout?.production ?? .digital },set:model.setProduction)) {
            Text("Dijital").tag(ProductionType.digital); Text("Ofset").tag(ProductionType.offset)
        }.inspectorSetting(model,"Üretim Dijital Ofset","Mevcut otomatik kâğıt ve işaret tercihlerini seçer. Seçenekler: Dijital / Ofset. Örnek: Ofset seçimi sabitlenmemiş renk skalasını etkinleştirir.")
    }
    private var quantityControls: some View {
        HStack {
            Text(model.project.isBooklet || model.project.isLeafBinding ? "Yayın adedi" : "Adet")
            TextField("Otomatik",value:Binding<Int?>(get:{ model.basicQuantity },set:{ model.basicQuantity = $0 }),format:.number)
                .textFieldStyle(.roundedBorder)
        }.inspectorSetting(model,"Adet","Tekrarlı işte her iş için istenen bitmiş ürün adedidir. Boş değer: bir dolu tabaka. Örnek: tabaka kapasitesini aşan adet ek tabaka gerektirir. Kitap/yaprak yayın adedi İş maliyeti içinde saklanır.")
    }
    private var automaticControls: some View {
        GroupBox("Otomatik düzen") {
                    VStack(alignment: .leading,spacing: 8) {
                        Button("Otomatik düzenle") { model.requestAutomaticLayout() }
                            .disabled(model.project.pages.isEmpty || model.loading || model.autoArranging)
                        if model.autoArranging { ProgressView().controlSize(.small) }
                        if !(model.project.isBooklet && model.project.book != nil),let summary = model.project.autoLayout?.summary { Text(summary).font(.caption) }
                        Text("İçe aktarma elle seçilen ayarları korur. Otomatik düzenle tüm yerleşim ayarlarını sıfırlar; kâğıt kalınlığı, adet ve seri içeriği korunur.")
                            .font(.caption).foregroundStyle(DesignSystem.muted)
                    }.padding(5)
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
                        Picker("Çevirme",selection: $model.project.settings.turnMethod) {
                            Text("Ayrı kalıp").tag(TurnMethod.sheetwise)
                            Text("Yan çevirme").tag(TurnMethod.workAndTurn)
                            Text("Takla").tag(TurnMethod.workAndTumble)
                        }.inspectorSetting(model,"Çevirme",SettingGuidance.detail("Çevirme"))
                        if model.project.binding != .stepAndRepeat && model.project.settings.turnMethod != .sheetwise {
                            Text("Aynı kalıpta iki yarım; tabaka başına iki kopya.").font(.caption).foregroundStyle(DesignSystem.muted)
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
                        }.inspectorSetting(model,"Tabaka seçimi",SettingGuidance.detail("Tabaka seçimi"))
                        Picker(model.autoLabel("Boyut",.sheetSize),selection: presetBinding) {
                            Text(Workspace.automaticSheetTitle).tag(Workspace.automaticSheetTitle)
                            ForEach(["A5","A4","A3","SRA3","33×48","35×50","50×70","70×100","Özel"],id: \.self) { Text($0) }
                        }.automaticReset(model,.sheetSize)
                        Text("Kullanılan: \(SmartAutoLayout.presetName(for: model.project.sheet.size)) · \(model.project.sheet.size.width,specifier: "%.0f")×\(model.project.sheet.size.height,specifier: "%.0f") mm")
                            .font(.caption).foregroundStyle(DesignSystem.muted)
                        if model.sheetPreset == "Özel" {
                            measurement("Genişlik",$model.project.sheet.size.width,autoField: .sheetSize,range: 20...3000)
                            measurement("Yükseklik",$model.project.sheet.size.height,autoField: .sheetSize,range: 20...3000)
                        }
                        Picker(model.autoLabel("Yön",.orientation),selection: model.autoBinding($model.project.sheet.orientation,.orientation)) {
                            Text("Otomatik").tag(Orientation.auto)
                            Text("Dikey").tag(Orientation.portrait)
                            Text("Yatay").tag(Orientation.landscape)
                        }.automaticReset(model,.orientation)
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
                        Picker(model.autoLabel("Maşa kenarı",.gripperEdge),selection: model.autoBinding($model.project.sheet.gripperEdge,.gripperEdge)) {
                            Text("Alt").tag(ImpositionCore.Edge.bottom); Text("Üst").tag(ImpositionCore.Edge.top)
                            Text("Sol").tag(ImpositionCore.Edge.left); Text("Sağ").tag(ImpositionCore.Edge.right)
                        }.automaticReset(model,.gripperEdge)
                        measurement("Maşa payı",$model.project.sheet.gripperWidth,autoField: .gripperWidth)
                        if model.project.isBooklet {
                            Text("Kat komşuları: 0 mm (sabit)").font(.caption).foregroundStyle(DesignSystem.muted)
                        } else {
                            measurement("Ara boşluk",$model.project.sheet.gutter,autoField: .gutter)
                        }
                    }.padding(5)
                }
    }
    private var markControls: some View {
        GroupBox("Taşma ve İşaretler") {
                    VStack(spacing: 10) {
                        if model.project.binding != .gang { measurement("Taşma",guide(\.bleed,field: .bleed,overlay: \.bleed),autoField: .bleed,range: 0...30) }
                        measurement("Kesim uzunluğu",guide(\.cropMarkLength,field: .cropLength,overlay: \.crop),autoField: .cropLength,range: 0...30)
                        if model.project.settings.cropMarkLength > 0 {
                            measurement("Kesim uzaklığı",guide(\.cropMarkOffset,field: .cropOffset,overlay: \.crop),autoField: .cropOffset,range: 0...30)
                        }
                        Text(model.autoLabel("Çıktı kesim işareti: "+(model.project.exportMarks.crop ? "Açık" : "Kapalı"),.exportCrop))
                            .font(.caption).foregroundStyle(DesignSystem.muted).automaticReset(model,.exportCrop)
                        measurement("Güvenli alan",guide(\.safeAreaInset,field: .safeArea,overlay: \.safeArea),autoField: .safeArea,range: 0...30)
                    }.padding(5)
                }
    }
    private var overlayControls: some View {
        GroupBox("Önizleme Katmanları") {
                    VStack(alignment: .leading,spacing: 8) {
                        Toggle("Kesim işaretleri",isOn: $model.overlays.crop).inspectorSetting(model,"Kesim işaretleri",SettingGuidance.detail("Kesim işaretleri"))
                        if model.project.isLeafBinding { Toggle("Delik kılavuzları",isOn:$model.overlays.punch).inspectorSetting(model,"Delik kılavuzları",SettingGuidance.detail("Delik kılavuzları")) }
                        if model.project.binding != .stepAndRepeat && model.project.binding != .gang { Toggle("Katlama çizgileri",isOn: $model.overlays.fold).inspectorSetting(model,"Katlama çizgileri",SettingGuidance.detail("Katlama çizgileri")) }
                        Toggle("Taşma çizgileri",isOn: $model.overlays.bleed).inspectorSetting(model,"Taşma çizgileri",SettingGuidance.detail("Taşma çizgileri"))
                        Toggle("Güvenli alan",isOn: $model.overlays.safeArea).inspectorSetting(model,"Güvenli alan",SettingGuidance.detail("Güvenli alan"))
                        Toggle("Sayfa numaraları",isOn: $model.overlays.pageNumbers).inspectorSetting(model,"Sayfa numaraları",SettingGuidance.detail("Sayfa numaraları"))
                        Toggle("Tabaka sınırı",isOn: $model.overlays.sheetBoundary).inspectorSetting(model,"Tabaka sınırı",SettingGuidance.detail("Tabaka sınırı"))
                        Toggle("Kenar payı / maşa",isOn: $model.overlays.pressGuides).inspectorSetting(model,"Kenar payı / maşa",SettingGuidance.detail("Kenar payı / maşa"))
                        Toggle("Renk skalası",isOn: Binding(get: { model.overlays.colorBar },set: model.setPreviewColorBar)).inspectorSetting(model,"Renk skalası",SettingGuidance.detail("Renk skalası"))
                        Toggle("Diz işaretleri",isOn: Binding(get: { model.overlays.registrationTargets },set: model.setPreviewTargets)).inspectorSetting(model,"Diz işaretleri",SettingGuidance.detail("Diz işaretleri"))
                        if model.overlays.colorBar || model.overlays.registrationTargets { ColorControlSizeView(model: model) }
                    }.toggleStyle(.checkbox).frame(maxWidth: .infinity,alignment: .leading).padding(5)
                }
    }
    private func guide(_ key: WritableKeyPath<ImpositionSettings,Double>,field: AutoLayoutField,overlay: WritableKeyPath<PreviewOverlays,Bool>) -> Binding<Double> {
        Binding(get: { model.project.settings[keyPath: key] },set: {
            model.markManual(field)
            model.project.settings[keyPath: key] = $0
            model.overlays[keyPath: overlay] = true
        })
    }
    private var generatedBleedControls: some View {
        GroupBox("Üretilmiş Taşma") {
            VStack(alignment: .leading,spacing: 9) {
                if (model.selectedGangJob?.bleed ?? model.project.settings.bleed) > 0 {
                    Toggle(model.autoLabel("Taşma üret",.generatedEnabled),isOn: model.autoBinding($model.editableGeneratedBleed.enabled,.generatedEnabled)).toggleStyle(.checkbox).automaticReset(model,.generatedEnabled)
                    if model.editableGeneratedBleed.enabled {
                        Picker(model.autoLabel("Yöntem",.generatedMethod),selection: model.autoBinding($model.editableGeneratedBleed.method,.generatedMethod)) {
                            Text("Otomatik (zemin rengi)").tag(GeneratedBleedMethod.automatic)
                            Text("Yansıt").tag(GeneratedBleedMethod.mirror)
                            Text("Renk").tag(GeneratedBleedMethod.solidColor)
                        }.automaticReset(model,.generatedMethod)
                        if model.editableGeneratedBleed.method == .automatic {
                            measurement("Tolerans (%)",Binding(get: { model.editableGeneratedBleed.tolerance*100 },
                                set: { model.editableGeneratedBleed.tolerance = $0/100 }),autoField: .generatedTolerance,range: 0...100)
                            Text("Tek renk kenar: vektör dolgu. Değişken kenar: kenar piksellerini uzat.").font(.caption).foregroundStyle(DesignSystem.muted)
                        }
                        if model.editableGeneratedBleed.method == .solidColor {
                            Picker(model.autoLabel("Renk uzayı",.generatedColor),selection: Binding(get: { model.editableGeneratedBleed.color.components.count == 4 },
                                set: { model.markManual(.generatedColor); model.editableGeneratedBleed.color = $0 ? .cmyk(0,0,0,0) : .rgb(1,1,1) })) {
                                Text("CMYK").tag(true); Text("RGB").tag(false)
                            }.automaticReset(model,.generatedColor)
                            let names = model.editableGeneratedBleed.color.components.count == 4 ? ["C","M","Y","K"] : ["R","G","B"]
                            ForEach(Array(names.enumerated()),id: \.offset) { index,name in
                                measurement(name+" (%)",colorComponent(index),autoField: .generatedColor,range: 0...100)
                            }
                        }
                        if let summary = model.bleedSampleSummary { Text(summary).font(.caption).foregroundStyle(DesignSystem.muted) }
                        Text("Yalnız kesim dışını değiştirir. Sıfır ara boşlukta blok çevresi üretilir.").font(.caption).foregroundStyle(DesignSystem.muted)
                    }
                } else { Text("Üretim için taşma payını artırın.").font(.caption).foregroundStyle(DesignSystem.muted) }
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
                if (model.source?.pages.count ?? model.project.pages.count) > 1 {
                    Picker("Sayfa düzeni",selection: Binding(get: { model.pageLayoutMode },set: model.setPageLayout)) {
                        Text("Otomatik").tag(PageLayout.automatic)
                        Text("Çift yüz (1–2 ön/arka, 3–4…)").tag(PageLayout.duplex)
                        Text("Tek yüz (her sayfa ayrı iş)").tag(PageLayout.simplex)
                    }.inspectorSetting(model,"Sayfa düzeni",SettingGuidance.detail("Sayfa düzeni"))
                }
                Text(model.pageLayoutSummary).font(.caption).foregroundStyle(DesignSystem.muted)
                Picker(model.autoLabel("Dizilim",.gutter),selection: Binding(get: { model.repeatArrangement },set: model.setRepeatArrangement)) {
                    Text("Bitişik (ara boşluk 0)").tag(RepeatArrangement.adjacent)
                    Text("Aralıklı (ara boşluk = 2 × taşma)").tag(RepeatArrangement.spaced)
                    Text("Özel (elle ara boşluk)").tag(RepeatArrangement.custom)
                }.automaticReset(model,.gutter)
                Text(model.repeatArrangement == .adjacent ? "Ortak kesim; taşma sadece blok çevresinde." : model.repeatArrangement == .spaced ? "Otomatik ara boşluk taşmanın iki katıdır." : "Elle belirlenen ara boşluk korunur.")
                    .font(.caption).foregroundStyle(DesignSystem.muted)
                Toggle(model.autoLabel("90° döndürmeye izin ver",.allowRotation),isOn: model.autoBinding($model.project.stepAndRepeat.allowRotation,.allowRotation)).automaticReset(model,.allowRotation)
                gridOverride("Sütun",value: $model.project.stepAndRepeat.columns,
                             automatic: model.currentSheet?.repeatLayout?.columns ?? 1,field: .columns)
                gridOverride("Satır",value: $model.project.stepAndRepeat.rows,
                             automatic: model.currentSheet?.repeatLayout?.rows ?? 1,field: .rows)
                Toggle("Adet hesapla (her iş için)",isOn: Binding(
                    get: { model.project.stepAndRepeat.quantity != nil },
                    set: { model.project.stepAndRepeat.quantity = $0 ? 1000 : nil })).inspectorSetting(model,"Adet hesapla (her iş için)",SettingGuidance.detail("Adet hesapla (her iş için)"))
                if model.project.stepAndRepeat.quantity != nil {
                    HStack {
                        Text("Adet")
                        TextField("Adet",value: Binding(get: { model.project.stepAndRepeat.quantity ?? 1000 },
                            set: { model.project.stepAndRepeat.quantity = $0 }),format: .number)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).accessibilityLabel("Adet")
                    }
                }
                FireControlsView(model: model)
                if let sheet = model.currentSheet, let layout = sheet.repeatLayout {
                    Text("\(layout.columns) × \(layout.rows) = \(layout.copiesPerSheet) adet/tabaka").fontWeight(.medium)
                    if model.project.autoLayout?.automaticFields.contains(.allowRotation) == true {
                        Text("Ürün dönüşü: \(sheet.front.slots.first?.rotation ?? 0)° · Otomatik").font(.caption)
                    }
                    Text("Bu iş: \(sheet.repeatCount) tabaka · Üretim: \(sheet.producedQuantityDescription) adet")
                    Text("Tüm işler: \(model.plan.totalPressSheets) tabaka")
                }
                Text(model.project.sheet.gutter == 0 ? "Ortak kesim: iç taşmalar sınırda kırpılır." : "Ara boşluk, komşu taşma kutuları arasında ölçülür.")
                    .font(.caption).foregroundStyle(DesignSystem.muted)
                if model.project.settings.turnMethod != .sheetwise {
                    Text("Aynı kalıp iki yüzde kullanılır. Çevirme eksenindeki ürün sayısı çift olmalıdır.")
                        .font(.caption).foregroundStyle(DesignSystem.muted)
                }
            }.toggleStyle(.checkbox).padding(5)
        }
    }
    private func gridOverride(_ title: String,value: Binding<Int?>,automatic: Int,field: AutoLayoutField) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            Toggle(model.autoLabel("\(title) sayısını belirle",field),isOn: Binding(get: { value.wrappedValue != nil },
                set: { model.markManual(field); value.wrappedValue = $0 ? min(200,automatic) : nil })).automaticReset(model,field)
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
                TextField(title,value:effective,format:.number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width:65)
                    .accessibilityLabel(title).focused($focusedField,equals:autoField)
                Text(title.contains("%") ? "%" : "mm").font(.caption).foregroundStyle(DesignSystem.muted)
                Stepper(title,value:effective,in:range,step:1).labelsHidden().fixedSize().accessibilityLabel(title)
            }
            if let autoField { AutomaticPill(model:model,field:autoField) }
        }.simultaneousGesture(TapGesture().onEnded { model.ui.focusedArea = autoField.flatMap(WorkflowPresentation.focus) })
            .inspectorSetting(model,title,autoField.map(SettingGuidance.detail) ?? "Ölçülmüş değeri girin. Birim: alan etiketindeki mm veya yüzde. Örnek: değişiklik mevcut önizlemeye yansır.")
    }
}
