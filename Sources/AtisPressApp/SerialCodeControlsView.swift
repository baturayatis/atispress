import SwiftUI
import ImpositionCore

struct SerialCodeControlsView: View {
    @Binding var field: SerialField
    var body: some View {
        VStack(alignment: .leading,spacing: 7) {
            TextField("İçerik şablonu",text: $field.codeSettings.template).textFieldStyle(.roundedBorder)
            Text("{no}: önek + basamak + sonek. Yer tutucu yoksa içerik sabittir.").font(.caption).foregroundStyle(.secondary)
            Text("Örnek: \((field.content(at: 0) ?? "Geçersiz").prefix(256))").font(.caption).textSelection(.enabled)
            measurement(field.kind == .qr ? "Boyut (mm, kare)" : "Genişlik (mm)",$field.codeSettings.width)
            if field.kind == .code128 { measurement("Çubuk yüksekliği (mm)",$field.codeSettings.height) }
            if field.kind == .qr {
                Picker("Hata düzeltme",selection: $field.codeSettings.correction) {
                    ForEach(SerialCodeSettings.Correction.allCases,id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                Text("Sessiz alan (modül)")
                TextField("Sessiz alan",value: $field.codeSettings.quietZone,format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
            }
            Toggle("Altına okunabilir metin yaz",isOn: $field.codeSettings.humanReadable).toggleStyle(.checkbox)
            Text("Konum, sessiz alanın sol alt köşesidir; boyut sessiz alanı içerir. QR’da dört kenar, Code 128’de sağ/sol korunur. Beyaz zemin üzerine vektör basılır.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func measurement(_ title: String,_ value: Binding<Double>) -> some View {
        HStack {
            Text(title); Spacer()
            TextField(title,value: value,format: .number.precision(.fractionLength(0...3))).frame(width: 70).textFieldStyle(.roundedBorder)
        }
    }
}
