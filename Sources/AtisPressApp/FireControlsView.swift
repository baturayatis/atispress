import SwiftUI
import ImpositionCore

struct FireControlsView: View {
    @ObservedObject var model: Workspace
    private var waste: Binding<WasteSettings> {
        Binding(get: { model.project.stepAndRepeat.waste ?? WasteSettings() },set: { model.project.stepAndRepeat.waste = $0 })
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack {
                Text("Fire")
                Picker("Fire türü",selection: waste.mode) {
                    Text("Yüzde (%)").tag(WasteSettings.Mode.percent)
                    Text("Sabit adet").tag(WasteSettings.Mode.fixed)
                }.labelsHidden()
                if waste.wrappedValue.mode == .percent {
                    TextField("Fire (%)",value: waste.percent,format: .number).frame(width: 65).textFieldStyle(.roundedBorder)
                } else {
                    TextField("Fire adedi",value: waste.fixed,format: .number).frame(width: 65).textFieldStyle(.roundedBorder)
                }
            }
            Picker("Fire kopyalar",selection: waste.numberCopies) {
                Text("Numarasız").tag(false); Text("Numaralı").tag(true)
            }
            if waste.wrappedValue.numberCopies {
                Text("Seri aralığı fireyi içerir. Bitiş no, müşteri adedini belirler.").font(.caption).foregroundStyle(.secondary)
            }
            if let sheet = model.currentSheet,let summary = sheet.productionSummary { Text(summary).font(.caption).textSelection(.enabled) }
            else { Text("Fire, Adet üzerine eklenir; yüzde yukarı yuvarlanır.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
