import SwiftUI
import ImpositionCore

struct LeafInspectorView: View {
    @ObservedObject var model: Workspace
    var section:Int? = nil
    private var settings: Binding<LeafBindingSettings> { $model.project.leafSettings }
    var body: some View {
        GroupBox("Yaprak cilt: katlama yok") {
            VStack(alignment:.leading,spacing:9) {
                if section==nil || section==0 {
                Picker("Cilt kenarı",selection:model.leafSettingBinding(\.edge)) {
                    Text("Sol").tag(LeafBindingSettings.BindingEdge.left)
                    Text("Üst").tag(LeafBindingSettings.BindingEdge.top)
                    Text("Sağ").tag(LeafBindingSettings.BindingEdge.right)
                }.inspectorTarget("bindingEdge").inspectorSetting(model,"Cilt kenarı",SettingGuidance.detail("Cilt kenarı"))
                Toggle("90° döndürmeye izin ver",isOn:model.autoBinding($model.project.stepAndRepeat.allowRotation,.allowRotation)).automaticReset(model,.allowRotation)
                input("Cilt payı (mm)",settings.allowance)
                Picker("Cilt payı davranışı",selection:model.leafSettingBinding(\.behavior)) {
                    Text("Koru").tag(BindingAllowanceBehavior.preserve)
                    Text("Küçült").tag(BindingAllowanceBehavior.shrink)
                    Text("Kaydır").tag(BindingAllowanceBehavior.shift)
                }.pickerStyle(.segmented).inspectorSetting(model,"Cilt payı davranışı",SettingGuidance.detail("Cilt payı davranışı"))
                if (model.project.leafSettings.allowance ?? 0)==0 { Text("Cilt payı girilmedi; makinenizin gerektirdiği payı girin.").foregroundStyle(DesignSystem.warning) }
                Text("Kesim ölçüsü korunur. Koru: baskı içeriği değişmez. Küçült: güvenli alana orantılı sığdırır. Kaydır: cilt kenarından uzaklaştırır; taşan baskı içeriği kırpılmaz.").font(.system(size:12))
                Toggle("Delik işaretleri (çıktıya basılır)",isOn:model.leafSettingBinding(\.holes)).inspectorTarget("holes").inspectorSetting(model,"Delik işaretlerini çıktıya ekle",SettingGuidance.detail("Delik işaretlerini çıktıya ekle"))
                if model.project.leafSettings.holes {
                    input("Delik aralığı (mm)",settings.pitch)
                    input("Delik çapı (mm)",settings.diameter)
                    input("Kenardan uzaklık (mm)",settings.offset)
                    Text("Delik kılavuzları kesim kenarının dışındaki boş kenara basılır; taşma veya komşu baskı içeriği üzerine basılmaz. Delik dizisi kenar boyunca ortalanır.").font(.system(size:12))
                }
                }
                ForEach(Array(model.plan.sheets.compactMap(\.leafInfo).filter { !$0.cover }.prefix(1).enumerated()),id:\.offset) { _,info in Text(TRFormat.presentation(info.summary)).font(.system(size:12)) }
            }.textFieldStyle(.roundedBorder).padding(5)
        }
    }
    private func input(_ title: String,_ value: Binding<Double?>) -> some View {
        HStack { Text(title).frame(maxWidth:.infinity,alignment:.leading); DimensionInput(title,value:Binding(get:{ value.wrappedValue ?? 0 },set:{ value.wrappedValue = $0 }),range:0...1000) }.inspectorSetting(model,title,SettingGuidance.detail(title))
    }
}
