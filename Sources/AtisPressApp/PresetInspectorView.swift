import SwiftUI
import UniformTypeIdentifiers

struct PresetInspectorView: View {
    @ObservedObject var model: Workspace
    @State private var name = ""
    private var selected: JobPreset? { model.presets.first { $0.id==model.selectedPresetID } }
    var body: some View {
        GroupBox("Hazır ayarlar") {
            VStack(alignment:.leading,spacing:8) {
                Picker("Hazır ayar",selection:$model.selectedPresetID) {
                    Text("Seçiniz").tag(nil as UUID?)
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Hazır ayar uygula") { if let selected { model.applyPreset(selected) } }.disabled(selected == nil)
                LabeledContent("Hazır ayar adı") { TextField("Ad",text:$name).textFieldStyle(.roundedBorder) }
                Button("Yeni hazır ayar kaydet") { run { _ = try model.savePreset(name:name); name = "" } }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                HStack {
                    Button("Yeniden adlandır") { if let selected { run { try model.renamePreset(selected.id,to:name) } } }.disabled(selected == nil || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button("Çoğalt") { if let selected { run { try model.duplicatePreset(selected.id) } } }.disabled(selected == nil)
                    Button("Sil") { if let selected { run { try model.deletePreset(selected.id) } } }.disabled(selected == nil)
                }.font(.caption)
                HStack {
                    Button("Paket içe aktar…",action:model.choosePresetImport)
                    Button("Paket dışa aktar…",action:model.choosePresetExport)
                }.font(.caption)
                if let name = model.project.autoLayout?.presetName {
                    Text("Hazır ayar kaynağı: "+name+". PDF, sayfa seçimi, adet/fire ve seri alanları korunur.").font(.caption).foregroundStyle(DesignSystem.muted)
                } else { Text("PDF, sayfa seçimi, adet/fire ve seri alanları hazır ayara kaydedilmez.").font(.caption).foregroundStyle(DesignSystem.muted) }
            }.padding(5)
        }.disabled(model.loading || model.exporting || model.autoArranging)
    }
    private func run(_ action: () throws -> Void) { do { try action() } catch { model.error = error.localizedDescription } }

}
extension UTType { static let atispresetpack = UTType(exportedAs:"com.atispress.presetpack",conformingTo:.json) }
