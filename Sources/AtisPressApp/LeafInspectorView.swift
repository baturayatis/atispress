import SwiftUI
import ImpositionCore

struct LeafInspectorView: View {
    @ObservedObject var model: Workspace
    private var settings: Binding<LeafBindingSettings> { $model.project.leafSettings }
    var body: some View {
        GroupBox("Yaprak cilt: katlama yok") {
            VStack(alignment:.leading,spacing:9) {
                Picker("Cilt kenarı",selection:Binding(get:{ model.project.leafSettings.edge },set:{ model.project.leafSettings.edge = $0; model.overlays.pressGuides = true; model.overlays.safeArea = true })) {
                    Text("Sol").tag(LeafBindingSettings.BindingEdge.left)
                    Text("Üst").tag(LeafBindingSettings.BindingEdge.top)
                    Text("Sağ").tag(LeafBindingSettings.BindingEdge.right)
                }.inspectorSetting(model,"Cilt kenarı",SettingGuidance.detail("Cilt kenarı"))
                Toggle(model.autoLabel("90° döndürmeye izin ver",.allowRotation),isOn:model.autoBinding($model.project.stepAndRepeat.allowRotation,.allowRotation)).automaticReset(model,.allowRotation)
                input("Cilt payı (mm)",settings.allowance)
                Picker("Cilt payı davranışı",selection:Binding(get:{ model.project.leafSettings.behavior },set:{ model.project.leafSettings.behavior = $0; model.overlays.pressGuides = true; model.overlays.safeArea = true })) {
                    Text("Koru").tag(BindingAllowanceBehavior.preserve)
                    Text("Küçült").tag(BindingAllowanceBehavior.shrink)
                    Text("Kaydır").tag(BindingAllowanceBehavior.shift)
                }.inspectorSetting(model,"Cilt payı davranışı",SettingGuidance.detail("Cilt payı davranışı"))
                if (model.project.leafSettings.allowance ?? 0)==0 { Text("Cilt payı girilmedi; makinenizin gerektirdiği payı girin.").foregroundStyle(.orange) }
                Text("Kesim ölçüsü korunur. Koru: artwork değişmez. Küçült: güvenli alana orantılı sığdırır. Kaydır: cilt kenarından uzaklaştırır; taşan artwork kırpılmaz.").font(.caption)
                Toggle("Delik işaretlerini çıktıya ekle",isOn:Binding(get:{ model.project.leafSettings.holes },set:{ model.project.leafSettings.holes = $0; model.overlays.punch = true })).inspectorSetting(model,"Delik işaretlerini çıktıya ekle",SettingGuidance.detail("Delik işaretlerini çıktıya ekle"))
                if model.project.leafSettings.holes {
                    input("Delik aralığı (mm)",settings.pitch)
                    input("Delik çapı (mm)",settings.diameter)
                    input("Kenardan uzaklık (mm)",settings.offset)
                    Text("Delik kılavuzları kesim kenarının dışındaki boş kenara basılır; taşma veya komşu artwork üzerine basılmaz. Delik dizisi kenar boyunca ortalanır.").font(.caption)
                }
                Picker("Kapak modu",selection:$model.project.coverMode) {
                    Text("İç sayfalara dahil").tag(CoverMode.included)
                    Text("Hariç — ayrı bas").tag(CoverMode.excluded)
                    Text("Ayrı PDF").tag(CoverMode.separate)
                }.inspectorSetting(model,"Kapak modu",SettingGuidance.detail("Kapak modu"))
                if model.project.coverMode != .included {
                    if model.project.coverMode == .separate { Button("Kapak PDF yükle…",action:model.chooseCoverPDF) }
                    coverPicker("Ön kapak",\.front)
                    coverPicker("Arka kapak",\.back)
                    Text("Kapaklar ayrı yaprak olarak basılır; iç yüzleri boştur. Aynı cilt payı uygulanır.").font(.caption)
                }
                ForEach(Array(model.plan.sheets.compactMap(\.leafInfo).filter { !$0.cover }.prefix(1).enumerated()),id:\.offset) { _,info in Text(info.summary).font(.caption) }
            }.textFieldStyle(.roundedBorder).padding(5)
        }
    }
    private func input(_ title: String,_ value: Binding<Double?>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value:Binding(get:{ value.wrappedValue ?? 0 },set:{ value.wrappedValue = $0; model.overlays.pressGuides = true; model.overlays.safeArea = true; model.overlays.punch = true }),format:.number).frame(width:70) }.inspectorSetting(model,title,SettingGuidance.detail(title))
    }
    private func coverPicker(_ title: String,_ key: WritableKeyPath<CoverSelection,Int?>) -> some View {
        Picker(title,selection:Binding(get:{ model.bookSettings.selection[keyPath:key] ?? -1 },set:{ model.bookSettings.selection[keyPath:key] = $0<0 ? nil : $0 })) {
            Text("Otomatik (ilk / son)").tag(-1)
            ForEach(model.project.book == nil ? model.project.pages : model.bookCoverDomain,id:\.number) { p in Text(model.coverPageLabel(p.number)).tag(p.number) }
        }
    }
}
