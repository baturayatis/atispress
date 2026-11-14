import SwiftUI

struct ExportPreparationView: View {
    @ObservedObject var model:Workspace
    @State private var details = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("PDF’i Hazırla / Dışa Aktar").font(.title2.bold())
            Text("Hazır seçimler yalnız çıktı işaretlerini değiştirir. Açılışta mevcut tercihleriniz korunur.").foregroundStyle(.secondary)
            HStack {
                ForEach(ExportPreset.allCases,id:\.self) { preset in
                    Button(preset.rawValue) { model.project.exportMarks = preset.applying(to:model.project.exportMarks) }
                }
                SettingHelp(title:"Çıktı hazır seçimleri",detail:"Matbaaya gönder: kesim, katlama, bilgi şeridi, renk skalası ve dizler. Dijital baskı: kesim. Kontrol çıktısı: kesim, katlama, taşma, güvenli alan, sayfa numaraları ve bilgi şeridi. Mevcut çizgi rengi, kalınlığı ve ölçüler korunur; bu seçimler PDF/X dönüşümü yapmaz.")
            }
            DisclosureGroup("İşaret ayrıntıları",isExpanded:$details) { ExportMarksView(model:model) }
            Text(model.statusSummary).font(.caption)
            HStack {
                Button("İptal") { model.preparingExport = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Menu("Diğer çıktı") { Button("Her tabaka — ayrı PDF…") { proceed(perSheet:true) } }
                Button("Bütün işi dışa aktar…") { proceed(perSheet:false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width:620)
    }
    private func proceed(perSheet:Bool) {
        model.preparingExport = false
        DispatchQueue.main.async { model.chooseExport(perSheet:perSheet) }
    }
}
