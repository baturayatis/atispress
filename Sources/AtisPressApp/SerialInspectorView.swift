import SwiftUI
import ImpositionCore

struct SerialInspectorView: View {
    @ObservedObject var model: Workspace
    private var job: Int { model.currentSheet?.repeatLayout?.jobIndex ?? 0 }
    private var fields: [SerialField] { model.project.serialFields.filter { $0.jobIndex == job } }
    var body: some View {
        GroupBox("Seri Numara") {
            VStack(alignment: .leading,spacing: 9) {
                if model.project.binding == .stepAndRepeat {
                    Text("İş \(job+1) · Sol alt kesim köşesinden metin başlangıcı (mm)").font(.caption)
                    Button("Alan Ekle") { model.addSerialField() }.disabled(model.project.serialFields.count >= 100)
                    ForEach(fields) { field in
                        Button {
                            model.selectedSerialID = field.id
                        } label: {
                            HStack {
                                Image(systemName: model.selectedSerialID == field.id ? "largecircle.fill.circle" : "circle")
                                Text(field.text(at: 0) ?? "Geçersiz").lineLimit(1)
                            }
                        }.buttonStyle(.borderless)
                    }
                    if let index = model.project.serialFields.firstIndex(where: { $0.id == model.selectedSerialID && $0.jobIndex == job }) {
                        editor(index)
                    }
                    if !fields.isEmpty {
                        Text("Önizlemedeki numaraya tıklayın ve sürükleyin: 1 mm’ye oturur. Fazla üretilen kopyalar numarasızdır.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let sheet = model.currentSheet {
                            Stepper("Baskı tabakası: \(model.repetition+1) / \(sheet.repeatCount)",value: $model.repetition,in: 0...max(0,sheet.repeatCount-1))
                        }
                    }
                } else { Text("Seri numara için Tekrarlı (kartvizit/düz iş) modunu seçin.").font(.caption) }
            }.padding(5).frame(maxWidth: .infinity,alignment: .leading)
        }
    }
    private func editor(_ index: Int) -> some View {
        let field = $model.project.serialFields[index]
        return VStack(alignment: .leading,spacing: 8) {
            HStack {
                Button("Çoğalt") { model.duplicateSerialField(field.wrappedValue.id) }.disabled(model.project.serialFields.count >= 100)
                Button("Sil") { model.project.serialFields.remove(at: index); model.selectedSerialID = nil }
            }
            Picker("Mod",selection: field.mode) {
                Text("Sıralı").tag(SerialField.Mode.sequential)
                Text("İstif (kes ve istifle)").tag(SerialField.Mode.stack)
            }
            number("Başlangıç",field.start)
            number("Artış",field.step)
            Stepper("Basamak: \(field.wrappedValue.digits)",value: field.digits,in: 0...32)
            TextField("Önek",text: field.prefix).textFieldStyle(.roundedBorder)
            TextField("Sonek",text: field.suffix).textFieldStyle(.roundedBorder)
            Picker("Yazı tipi",selection: field.font) {
                ForEach(Array(Set(["Helvetica","Helvetica-Bold","Menlo-Regular","Times-Roman","Courier",field.wrappedValue.font])).sorted(),id: \.self) { Text($0).tag($0) }
            }
            TextField("Yazı tipi adı",text: field.font).textFieldStyle(.roundedBorder)
            if NSFont(name: field.wrappedValue.font,size: 12) == nil {
                Text("Yazı tipi bulunamadı; sistem yedeği kullanılır.").font(.caption).foregroundStyle(.orange)
            }
            number("Boyut (pt)",field.size)
            number("Dönüş (°)",field.rotation)
            Picker("Yüzler",selection: field.sides) {
                Text("Ön").tag(SerialField.Sides.front)
                Text("Arka").tag(SerialField.Sides.back)
                Text("Ön ve arka").tag(SerialField.Sides.both)
            }
            number("X (mm)",field.position.x)
            number("Y (mm)",field.position.y)
            Picker("Renk uzayı",selection: Binding(get: { field.wrappedValue.color.components.count == 4 },set: {
                field.wrappedValue.color = $0 ? .cmyk(0,0,0,1) : .rgb(0,0,0)
            })) { Text("CMYK").tag(true); Text("RGB").tag(false) }
            let names = field.wrappedValue.color.components.count == 4 ? ["C","M","Y","K"] : ["R","G","B"]
            ForEach(Array(names.enumerated()),id: \.offset) { channel,name in
                number(name+" (%)",Binding(get: { field.wrappedValue.color.components[channel]*100 },set: { value in
                    var components = field.wrappedValue.color.components
                    guard channel < components.count else { return }
                    components[channel] = value/100
                    field.wrappedValue.color = components.count == 4 ? .cmyk(components[0],components[1],components[2],components[3]) :
                        .rgb(components[0],components[1],components[2])
                }))
            }
            Text("Adet, Tekrarlı Yerleşim → Adet hesapla alanından alınır. Boşsa bir tam tabaka numaralanır.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func number(_ title: String,_ value: Binding<Int64>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value: value,format: .number).frame(width: 95).textFieldStyle(.roundedBorder) }
    }
    private func number(_ title: String,_ value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value: value,format: .number.precision(.fractionLength(0...2))).frame(width: 95).textFieldStyle(.roundedBorder) }
    }
}
