import SwiftUI
import ImpositionCore

struct SerialCodeControlsView: View {
    @ObservedObject var model:Workspace
    @Binding var field: SerialField
    var body: some View {
        VStack(alignment: .leading,spacing: 7) {
            LabeledContent("İçerik şablonu") { TextField("Şablon",text:$field.codeSettings.template).textFieldStyle(.roundedBorder) }.inspectorSetting(model,"İçerik şablonu QR barkod",SettingGuidance.detail("İçerik şablonu"))
            Text("{no}: önek + basamak + sonek. Yer tutucu yoksa içerik sabittir.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
            Text("Örnek: \((field.content(at: 0) ?? "Geçersiz").prefix(256))").font(.caption).textSelection(.enabled)
            measurement(field.kind == .qr ? "Boyut (mm, kare)" : "Genişlik (mm)",$field.codeSettings.width)
            if field.kind == .code128 { measurement("Çubuk yüksekliği (mm)",$field.codeSettings.height) }
            if field.kind == .qr {
                Picker("Hata düzeltme",selection: $field.codeSettings.correction) {
                    ForEach(SerialCodeSettings.Correction.allCases,id: \.self) { Text($0.rawValue).tag($0) }
                }.inspectorSetting(model,"Hata düzeltme",SettingGuidance.detail("Hata düzeltme"))
            }
            HStack {
                Text("Tarama boşluğu (birim)")
                Spacer()
                TextField("Sessiz alan",value:$field.codeSettings.quietZone,format:.number.locale(TRFormat.locale)).textFieldStyle(.roundedBorder).frame(width:72)
                Stepper("Sessiz alan",value:$field.codeSettings.quietZone,in:0...100).labelsHidden().fixedSize()
            }
            Toggle("Altına okunabilir metin yaz",isOn: $field.codeSettings.humanReadable).toggleStyle(.switch).inspectorSetting(model,"Altına okunabilir metin yaz",SettingGuidance.detail("Altına okunabilir metin yaz"))
            Text("Boyut, kodun çevresindeki boş tarama alanını da içerir.")
                .font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }
    }
    private func measurement(_ title: String,_ value: Binding<Double>) -> some View {
        HStack { Text(title).frame(maxWidth:.infinity,alignment:.leading); DimensionInput(title,value:value) }.inspectorSetting(model,title,SettingGuidance.detail(title))
    }
}
