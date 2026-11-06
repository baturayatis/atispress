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
                GroupBox("Ciltleme") {
                    VStack(alignment: .leading,spacing: 10) {
                        Picker("Yöntem",selection: $model.project.binding) {
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
                        if model.project.settings.turnMethod != .sheetwise {
                            Text("Aynı kalıpta iki yarım; tabaka başına iki kopya.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(5)
                }
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
                GroupBox("Önizleme Katmanları") {
                    VStack(alignment: .leading,spacing: 8) {
                        Toggle("Kesim işaretleri",isOn: $model.overlays.crop)
                        Toggle("Katlama çizgileri",isOn: $model.overlays.fold)
                        Toggle("Taşma çizgileri",isOn: $model.overlays.bleed)
                        Toggle("Güvenli alan",isOn: $model.overlays.safeArea)
                        Toggle("Sayfa numaraları",isOn: $model.overlays.pageNumbers)
                        Toggle("Tabaka sınırı",isOn: $model.overlays.sheetBoundary)
                    }.toggleStyle(.checkbox).frame(maxWidth: .infinity,alignment: .leading).padding(5)
                }
            }.padding(14)
        }
        .onChange(of: model.project.settings.bleed) { _,_ in model.overlays.bleed = true }
        .onChange(of: model.project.settings.cropMarkLength) { _,_ in model.overlays.crop = true }
        .onChange(of: model.project.settings.cropMarkOffset) { _,_ in model.overlays.crop = true }
        .onChange(of: model.project.settings.safeAreaInset) { _,_ in model.overlays.safeArea = true }
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
