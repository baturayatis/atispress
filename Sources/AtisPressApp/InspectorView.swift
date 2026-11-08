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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 16) {
                Text("Baskı Ayarları").font(.title2.bold())
                GroupBox("Otomatik düzen") {
                    VStack(alignment: .leading,spacing: 8) {
                        Picker("Üretim",selection: Binding(get: { model.project.autoLayout?.production ?? .digital },set: model.setProduction)) {
                            Text("Dijital").tag(ProductionType.digital)
                            Text("Ofset").tag(ProductionType.offset)
                        }
                        Button("Otomatik düzenle") { model.requestAutomaticLayout() }
                            .disabled(model.project.pages.isEmpty || model.loading || model.autoArranging)
                        if model.autoArranging { ProgressView().controlSize(.small) }
                        if !(model.project.isBooklet && model.project.book != nil),let summary = model.project.autoLayout?.summary { Text(summary).font(.caption) }
                        Text("İçe aktarma elle seçilen ayarları korur. Otomatik düzenle tüm yerleşim ayarlarını sıfırlar; kâğıt kalınlığı, adet ve seri içeriği korunur.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(5)
                }
                PresetInspectorView(model:model)
                Text("Tüm ölçüler mm").font(.caption).foregroundStyle(.secondary)
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
                        }
                        if model.project.binding == .perfectBound || model.project.binding == .sewn {
                            Picker("Forma",selection: $model.project.settings.signatureSize) {
                                Text("Otomatik").tag(SignatureSize.automatic)
                                Text("4 sayfa (tek kat)").tag(SignatureSize.four)
                                Text("8 sayfa").tag(SignatureSize.eight)
                                Text("16 sayfa").tag(SignatureSize.sixteen)
                                Text("32 sayfa").tag(SignatureSize.thirtyTwo)
                            }
                        }
                        Picker("Çevirme",selection: $model.project.settings.turnMethod) {
                            Text("Ayrı kalıp").tag(TurnMethod.sheetwise)
                            Text("Yan çevirme").tag(TurnMethod.workAndTurn)
                            Text("Takla").tag(TurnMethod.workAndTumble)
                        }
                        if model.project.binding != .stepAndRepeat && model.project.settings.turnMethod != .sheetwise {
                            Text("Aynı kalıpta iki yarım; tabaka başına iki kopya.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(5)
                }
                if model.project.binding == .stepAndRepeat { repeatControls }
                if model.project.binding == .gang { GangInspectorView(model: model) }
                if model.project.isLeafBinding { LeafInspectorView(model:model) }
                if model.project.isBooklet { BookInspectorView(model: model); BlankPlacementInspector(model:model) }
                GroupBox("Baskı Tabakası") {
                    VStack(spacing: 10) {
                        Picker("Tabaka seçimi",selection: Binding(get: { model.project.autoLayout?.sheetSelection ?? .fixed },set: model.setSheetSelection)) {
                            Text("Sabit").tag(SheetSelection.fixed)
                            Text("En verimli").tag(SheetSelection.efficient)
                            Text("Otomatik").tag(SheetSelection.automatic)
                        }
                        Picker(model.autoLabel("Boyut",.sheetSize),selection: presetBinding) {
                            Text(Workspace.automaticSheetTitle).tag(Workspace.automaticSheetTitle)
                            ForEach(["A5","A4","A3","SRA3","33×48","35×50","50×70","70×100","Özel"],id: \.self) { Text($0) }
                        }.automaticReset(model,.sheetSize)
                        Text("Kullanılan: \(SmartAutoLayout.presetName(for: model.project.sheet.size)) · \(model.project.sheet.size.width,specifier: "%.0f")×\(model.project.sheet.size.height,specifier: "%.0f") mm")
                            .font(.caption).foregroundStyle(.secondary)
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
                Picker(model.autoLabel("Hizalama",.alignment),selection:model.autoBinding($model.project.blockAlignment,.alignment)) {
                    Text("Ortala").tag(BlockAlignment.center)
                    Text("Maşa kenarına yasla").tag(BlockAlignment.gripper)
                }.automaticReset(model,.alignment)
                if model.project.binding == .gang && model.project.gang?.mode == .manual { Text("Elle yerleştirilmiş bloklar taşınmaz; hizalama otomatik düzen için uygulanır.").font(.caption).foregroundStyle(.secondary) }
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
                            Text("Kat komşuları: 0 mm (sabit)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            measurement("Ara boşluk",$model.project.sheet.gutter,autoField: .gutter)
                        }
                    }.padding(5)
                }
                GroupBox("Taşma ve İşaretler") {
                    VStack(spacing: 10) {
                        if model.project.binding != .gang { measurement("Taşma",guide(\.bleed,field: .bleed,overlay: \.bleed),autoField: .bleed,range: 0...30) }
                        measurement("Kesim uzunluğu",guide(\.cropMarkLength,field: .cropLength,overlay: \.crop),autoField: .cropLength,range: 0...30)
                        if model.project.settings.cropMarkLength > 0 {
                            measurement("Kesim uzaklığı",guide(\.cropMarkOffset,field: .cropOffset,overlay: \.crop),autoField: .cropOffset,range: 0...30)
                        }
                        Text(model.autoLabel("Çıktı kesim işareti: "+(model.project.exportMarks.crop ? "Açık" : "Kapalı"),.exportCrop))
                            .font(.caption).foregroundStyle(.secondary).automaticReset(model,.exportCrop)
                        measurement("Güvenli alan",guide(\.safeAreaInset,field: .safeArea,overlay: \.safeArea),autoField: .safeArea,range: 0...30)
                    }.padding(5)
                }
                PreflightView(model: model)
                SerialInspectorView(model: model)
                generatedBleedControls
                GroupBox("Önizleme Katmanları") {
                    VStack(alignment: .leading,spacing: 8) {
                        Toggle("Kesim işaretleri",isOn: $model.overlays.crop)
                        if model.project.isLeafBinding { Toggle("Delik kılavuzları",isOn:$model.overlays.punch) }
                        if model.project.binding != .stepAndRepeat && model.project.binding != .gang { Toggle("Katlama çizgileri",isOn: $model.overlays.fold) }
                        Toggle("Taşma çizgileri",isOn: $model.overlays.bleed)
                        Toggle("Güvenli alan",isOn: $model.overlays.safeArea)
                        Toggle("Sayfa numaraları",isOn: $model.overlays.pageNumbers)
                        Toggle("Tabaka sınırı",isOn: $model.overlays.sheetBoundary)
                        Toggle("Kenar payı / maşa",isOn: $model.overlays.pressGuides)
                        Toggle("Renk skalası",isOn: Binding(get: { model.overlays.colorBar },set: model.setPreviewColorBar))
                        Toggle("Diz işaretleri",isOn: Binding(get: { model.overlays.registrationTargets },set: model.setPreviewTargets))
                        if model.overlays.colorBar || model.overlays.registrationTargets { ColorControlSizeView(model: model) }
                    }.toggleStyle(.checkbox).frame(maxWidth: .infinity,alignment: .leading).padding(5)
                }
            }.padding(14)
        }.disabled(model.loading || model.autoArranging)
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
                            Text("Tek renk kenar: vektör dolgu. Değişken kenar: kenar piksellerini uzat.").font(.caption).foregroundStyle(.secondary)
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
                        if let summary = model.bleedSampleSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                        Text("Yalnız kesim dışını değiştirir. Sıfır ara boşlukta blok çevresi üretilir.").font(.caption).foregroundStyle(.secondary)
                    }
                } else { Text("Üretim için taşma payını artırın.").font(.caption).foregroundStyle(.secondary) }
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
                    }
                }
                Text(model.pageLayoutSummary).font(.caption).foregroundStyle(.secondary)
                Picker(model.autoLabel("Dizilim",.gutter),selection: Binding(get: { model.repeatArrangement },set: model.setRepeatArrangement)) {
                    Text("Bitişik (ara boşluk 0)").tag(RepeatArrangement.adjacent)
                    Text("Aralıklı (ara boşluk = 2 × taşma)").tag(RepeatArrangement.spaced)
                    Text("Özel (elle ara boşluk)").tag(RepeatArrangement.custom)
                }.automaticReset(model,.gutter)
                Text(model.repeatArrangement == .adjacent ? "Ortak kesim; taşma sadece blok çevresinde." : model.repeatArrangement == .spaced ? "Otomatik ara boşluk taşmanın iki katıdır." : "Elle belirlenen ara boşluk korunur.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.autoLabel("90° döndürmeye izin ver",.allowRotation),isOn: model.autoBinding($model.project.stepAndRepeat.allowRotation,.allowRotation)).automaticReset(model,.allowRotation)
                gridOverride("Sütun",value: $model.project.stepAndRepeat.columns,
                             automatic: model.currentSheet?.repeatLayout?.columns ?? 1,field: .columns)
                gridOverride("Satır",value: $model.project.stepAndRepeat.rows,
                             automatic: model.currentSheet?.repeatLayout?.rows ?? 1,field: .rows)
                Toggle("Adet hesapla (her iş için)",isOn: Binding(
                    get: { model.project.stepAndRepeat.quantity != nil },
                    set: { model.project.stepAndRepeat.quantity = $0 ? 1000 : nil }))
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
                    .font(.caption).foregroundStyle(.secondary)
                if model.project.settings.turnMethod != .sheetwise {
                    Text("Aynı kalıp iki yüzde kullanılır. Çevirme eksenindeki ürün sayısı çift olmalıdır.")
                        .font(.caption).foregroundStyle(.secondary)
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
        return HStack {
            Text(autoField.map { model.autoLabel(title,$0) } ?? title).frame(maxWidth: .infinity,alignment: .leading)
            TextField(title,value: effective,format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 65)
                .accessibilityLabel(title)
            Stepper(title,value: effective,in: range,step: 1).labelsHidden().fixedSize()
            if let autoField { AutomaticResetButton(model:model,field:autoField) }
        }
    }
}
