import SwiftUI
import ImpositionCore

struct InspectorView: View {
    @ObservedObject var model: Workspace
    @State private var preset = "50×70"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 16) {
                Text("Baskı Ayarları").font(.title2.bold())
                Text("Tüm ölçüler mm").font(.caption).foregroundStyle(.secondary)
                GroupBox("Yerleşim Yöntemi") {
                    VStack(alignment: .leading,spacing: 10) {
                        Picker("Yöntem",selection: Binding(get: { model.project.binding },set: model.setMode)) {
                            Text("Tekrarlı (kartvizit/düz iş)").tag(BindingMethod.stepAndRepeat)
                            Text("Tel dikiş").tag(BindingMethod.saddleStitch)
                            Text("Tutkallı cilt").tag(BindingMethod.perfectBound)
                        }
                        if model.project.binding == .perfectBound {
                            Picker("Forma",selection: $model.project.settings.signatureSize) {
                                Text("Otomatik").tag(SignatureSize.automatic)
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
                GroupBox("Baskı Tabakası") {
                    VStack(spacing: 10) {
                        Picker("Boyut",selection: $preset) {
                            ForEach(["A4","A3","SRA3","33×48","35×50","50×70","70×100","Özel"],id: \.self) { Text($0) }
                        }.onChange(of: preset) { _,value in
                            let presets: [String:SheetPreset] = ["A4":.a4,"A3":.a3,"SRA3":.sra3,"33×48":.cm33x48,
                                "35×50":.cm35x50,"50×70":.cm50x70,"70×100":.cm70x100]
                            if let selected = presets[value] { model.project.sheet.size = selected.size }
                        }
                        if preset == "Özel" {
                            measurement("Genişlik",$model.project.sheet.size.width,range: 20...3000)
                            measurement("Yükseklik",$model.project.sheet.size.height,range: 20...3000)
                        }
                        Picker("Yön",selection: $model.project.sheet.orientation) {
                            Text("Otomatik").tag(Orientation.auto)
                            Text("Dikey").tag(Orientation.portrait)
                            Text("Yatay").tag(Orientation.landscape)
                        }
                    }.padding(5)
                }
                GroupBox("Kenar Payları ve Maşa") {
                    VStack(spacing: 10) {
                        measurement("Sol",$model.project.sheet.margins.left)
                        measurement("Sağ",$model.project.sheet.margins.right)
                        measurement("Üst",$model.project.sheet.margins.top)
                        measurement("Alt",$model.project.sheet.margins.bottom)
                        Picker("Maşa kenarı",selection: $model.project.sheet.gripperEdge) {
                            Text("Alt").tag(ImpositionCore.Edge.bottom); Text("Üst").tag(ImpositionCore.Edge.top)
                            Text("Sol").tag(ImpositionCore.Edge.left); Text("Sağ").tag(ImpositionCore.Edge.right)
                        }
                        measurement("Maşa payı",$model.project.sheet.gripperWidth)
                        measurement("Ara boşluk",$model.project.sheet.gutter)
                    }.padding(5)
                }
                GroupBox("Taşma ve İşaretler") {
                    VStack(spacing: 10) {
                        measurement("Taşma",$model.project.settings.bleed,range: 0...30)
                        measurement("Kesim uzunluğu",$model.project.settings.cropMarkLength,range: 0...30)
                        if model.project.settings.cropMarkLength > 0 {
                            measurement("Kesim uzaklığı",$model.project.settings.cropMarkOffset,range: 0...30)
                        }
                        measurement("Güvenli alan",$model.project.settings.safeAreaInset,range: 0...30)
                    }.padding(5)
                }
                generatedBleedControls
                GroupBox("Önizleme Katmanları") {
                    VStack(alignment: .leading,spacing: 8) {
                        Toggle("Kesim işaretleri",isOn: $model.overlays.crop)
                        if model.project.binding != .stepAndRepeat { Toggle("Katlama çizgileri",isOn: $model.overlays.fold) }
                        Toggle("Taşma çizgileri",isOn: $model.overlays.bleed)
                        Toggle("Güvenli alan",isOn: $model.overlays.safeArea)
                        Toggle("Sayfa numaraları",isOn: $model.overlays.pageNumbers)
                        Toggle("Tabaka sınırı",isOn: $model.overlays.sheetBoundary)
                        Toggle("Kenar payı / maşa",isOn: $model.overlays.pressGuides)
                    }.toggleStyle(.checkbox).frame(maxWidth: .infinity,alignment: .leading).padding(5)
                }
            }.padding(14)
        }
        .onChange(of: model.project.settings.bleed) { _,_ in model.overlays.bleed = true }
        .onChange(of: model.project.settings.cropMarkLength) { _,_ in model.overlays.crop = true }
        .onChange(of: model.project.settings.cropMarkOffset) { _,_ in model.overlays.crop = true }
        .onChange(of: model.project.settings.safeAreaInset) { _,_ in model.overlays.safeArea = true }
    }
    private var generatedBleedControls: some View {
        GroupBox("Üretilmiş Taşma") {
            VStack(alignment: .leading,spacing: 9) {
                if model.project.settings.bleed > 0 {
                    Toggle("Taşma üret",isOn: $model.project.settings.generatedBleed.enabled).toggleStyle(.checkbox)
                    if model.project.settings.generatedBleed.enabled {
                        Picker("Yöntem",selection: $model.project.settings.generatedBleed.method) {
                            Text("Otomatik (zemin rengi)").tag(GeneratedBleedMethod.automatic)
                            Text("Yansıt").tag(GeneratedBleedMethod.mirror)
                            Text("Renk").tag(GeneratedBleedMethod.solidColor)
                        }
                        if model.project.settings.generatedBleed.method == .automatic {
                            measurement("Tolerans (%)",Binding(get: { model.project.settings.generatedBleed.tolerance*100 },
                                set: { model.project.settings.generatedBleed.tolerance = $0/100 }),range: 0...100)
                            Text("Tek renk kenar: vektör dolgu. Değişken kenar: kenar piksellerini uzat.").font(.caption).foregroundStyle(.secondary)
                        }
                        if model.project.settings.generatedBleed.method == .solidColor {
                            Picker("Renk uzayı",selection: Binding(get: { model.project.settings.generatedBleed.color.components.count == 4 },
                                set: { model.project.settings.generatedBleed.color = $0 ? .cmyk(0,0,0,0) : .rgb(1,1,1) })) {
                                Text("CMYK").tag(true); Text("RGB").tag(false)
                            }
                            let names = model.project.settings.generatedBleed.color.components.count == 4 ? ["C","M","Y","K"] : ["R","G","B"]
                            ForEach(Array(names.enumerated()),id: \.offset) { index,name in
                                measurement(name+" (%)",colorComponent(index),range: 0...100)
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
        Binding(get: { model.project.settings.generatedBleed.color.components[index]*100 },set: { value in
            var values = model.project.settings.generatedBleed.color.components
            values[index] = value/100
            model.project.settings.generatedBleed.color = values.count == 4 ?
                .cmyk(values[0],values[1],values[2],values[3]) : .rgb(values[0],values[1],values[2])
        })
    }
    private var repeatControls: some View {
        GroupBox("Tekrarlı Yerleşim") {
            VStack(alignment: .leading,spacing: 10) {
                Text("Seçili sırada 1–2 ön/arka, 3–4 ayrı iş… Tek kalan sayfanın arkası boş.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("90° döndürmeye izin ver",isOn: $model.project.stepAndRepeat.allowRotation)
                gridOverride("Sütun",value: $model.project.stepAndRepeat.columns,
                             automatic: model.currentSheet?.repeatLayout?.columns ?? 1)
                gridOverride("Satır",value: $model.project.stepAndRepeat.rows,
                             automatic: model.currentSheet?.repeatLayout?.rows ?? 1)
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
                if let sheet = model.currentSheet, let layout = sheet.repeatLayout {
                    Text("\(layout.columns) × \(layout.rows) = \(layout.copiesPerSheet) adet/tabaka").fontWeight(.medium)
                    Text("Bu iş: \(sheet.repeatCount) tabaka · Üretim: \(sheet.repeatCount*layout.copiesPerSheet) adet")
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
    private func gridOverride(_ title: String,value: Binding<Int?>,automatic: Int) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            Toggle("\(title) sayısını belirle",isOn: Binding(get: { value.wrappedValue != nil },
                set: { value.wrappedValue = $0 ? min(200,automatic) : nil }))
            if value.wrappedValue != nil {
                Stepper("\(title): \(value.wrappedValue ?? 1)",value: Binding(get: { value.wrappedValue ?? 1 },
                    set: { value.wrappedValue = $0 }),in: 1...200)
            }
        }
    }
    private func measurement(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double> = 0...200) -> some View {
        HStack {
            Text(title).frame(maxWidth: .infinity,alignment: .leading)
            TextField(title,value: value,format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 65)
                .accessibilityLabel(title)
            Stepper(title,value: value,in: range,step: 1).labelsHidden().fixedSize()
        }
    }
}
