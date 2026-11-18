import SwiftUI
import ImpositionCore

struct FireControlsView: View {
    @ObservedObject var model: Workspace
    private var waste: Binding<WasteSettings> {
        Binding(get: { model.workflowWaste }, set: { model.workflowWaste = $0 })
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack {
                Text("Fire").help("Ek üretim payı")
                Picker("Fire türü",selection: waste.mode) {
                    Text("Yüzde (%)").tag(WasteSettings.Mode.percent)
                    Text("Sabit adet").tag(WasteSettings.Mode.fixed)
                }.labelsHidden().inspectorSetting(model,"Fire türü",SettingGuidance.detail("Fire türü"))
            }
            HStack {
                Text("Ek üretim payı").frame(maxWidth:.infinity,alignment:.leading)
                if waste.wrappedValue.mode == .percent {
                    DimensionInput("Fire",value:waste.percent,unit:"%",range:0...100)
                } else {
                    IntegerInput(title:"Fire",value:waste.fixed)
                }
            }
            if model.project.team != nil {
                Text("Fire her düzenin fiziksel tabaka adedine eklenir.").font(.system(size:12))
                    .foregroundStyle(DesignSystem.muted)
            } else {
                Picker("Fire kopyalar",selection: waste.numberCopies) {
                    Text("Numarasız").tag(false); Text("Numaralı").tag(true)
                }.pickerStyle(.segmented).inspectorSetting(model,"Fire kopyalar",SettingGuidance.detail("Fire kopyalar"))
                if waste.wrappedValue.numberCopies {
                    Text("Seri aralığı fireyi içerir. Bitiş no, müşteri adedini belirler.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                }
            }
            if let sheet = model.currentSheet,let summary = sheet.productionSummary { Text(summary).font(.system(size:12)).textSelection(.enabled) }
            else { Text("Fire, Adet üzerine eklenir; yüzde yukarı yuvarlanır.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1) }
        }
    }
}
