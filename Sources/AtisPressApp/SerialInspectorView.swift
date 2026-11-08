import SwiftUI
import ImpositionCore

struct SerialInspectorView: View {
    @ObservedObject var model: Workspace
    @FocusState private var editingEnd: UUID?
    @State private var endDraft = ""
    private var job: Int { model.currentSheet?.repeatLayout?.jobIndex ?? 0 }
    private var fields: [SerialField] { model.editableSerialFields.filter { $0.jobIndex == job } }
    var body: some View {
        GroupBox("Seri Numara") {
            VStack(alignment: .leading,spacing: 9) {
                if model.project.binding == .stepAndRepeat || (model.project.binding == .gang && model.selectedGangJob != nil) {
                    Text("İş \(job+1) · Sol alt kesim köşesinden alan konumu (mm)").font(.caption)
                    HStack {
                        Text("Adet")
                        TextField("Adet",value: Binding(get: { model.serialQuantity(job: job) },
                            set: model.setSerialQuantity),format: .number)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Seri numara adedi")
                    }
                    FireControlsView(model: model)
                    if let sheet = model.currentSheet,sheet.unnumberedCopiesDescription != "0" {
                        Text("Fazla \(sheet.unnumberedCopiesDescription) kopya numarasız").font(.caption).foregroundStyle(.orange)
                    }
                    Button("Alan Ekle") { model.addSerialField() }.disabled(model.editableSerialFields.count >= 100)
                    ForEach(fields) { field in
                        VStack(alignment: .leading,spacing: 4) {
                            Button { model.selectedSerialID = field.id } label: {
                                HStack {
                                    Image(systemName: model.selectedSerialID == field.id ? "largecircle.fill.circle" : "circle")
                                    Text((field.kind == .text ? "" : field.kind == .qr ? "QR · " : "Code 128 · ")+(field.content(at: 0) ?? "Geçersiz")).lineLimit(1)
                                }
                            }.buttonStyle(.borderless)
                            Text(field.rangeDescription(quantity: model.serialNumberedQuantity(job: job),sheetCount: model.serialSheetCount(job: job)))
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    if let index = model.editableSerialFields.firstIndex(where: { $0.id == model.selectedSerialID && $0.jobIndex == job }) {
                        editor(index)
                    }
                    if !fields.isEmpty {
                        Text("Önizlemedeki numaraya tıklayın ve sürükleyin: 1 mm’ye oturur. Fire numaralama seçimi uygulanır; üretim adedini aşan yuvalar numarasızdır.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let sheet = model.currentSheet {
                            Stepper("Baskı tabakası: \(model.repetition+1) / \(sheet.repeatCount)",value: $model.repetition,in: 0...max(0,sheet.repeatCount-1))
                        }
                    }
                } else { Text(model.project.binding == .gang ? "Önce PDF ekleyin ve bir iş seçin." : "Seri numara için Tekrarlı (kartvizit/düz iş) modunu seçin.").font(.caption) }
            }.padding(5).frame(maxWidth: .infinity,alignment: .leading)
        }.onChange(of: editingEnd) { _,_ in syncEndDraft() }
            .onChange(of: model.project.stepAndRepeat.quantity) { _,_ in syncEndDraft() }
            .onChange(of: model.editableSerialFields) { _,_ in syncEndDraft() }
            .onChange(of: model.currentSheet?.repeatLayout?.copiesPerSheet) { _,_ in syncEndDraft() }
    }
    private func editor(_ index: Int) -> some View {
        let snapshot = model.editableSerialFields[index]
        let field = Binding(get: { model.editableSerialFields.first(where: { $0.id == snapshot.id }) ?? snapshot },set: { value in
            if let current = model.editableSerialFields.firstIndex(where: { $0.id == snapshot.id }) { model.editableSerialFields[current] = value }
        })
        return VStack(alignment: .leading,spacing: 8) {
            HStack {
                Button("Çoğalt") { model.duplicateSerialField(field.wrappedValue.id) }.disabled(model.editableSerialFields.count >= 100)
                Button("Sil") {
                    editingEnd = nil; NSApp?.keyWindow?.makeFirstResponder(nil)
                    model.editableSerialFields.removeAll { $0.id == snapshot.id }
                    model.serialInputErrors[snapshot.id] = nil; model.selectedSerialID = nil
                }
            }
            Picker("Tür",selection: field.kind) {
                Text("Metin").tag(SerialCodeSettings.Kind.text)
                Text("QR kod").tag(SerialCodeSettings.Kind.qr)
                Text("Barkod (Code 128)").tag(SerialCodeSettings.Kind.code128)
            }
            if field.wrappedValue.kind != .text { SerialCodeControlsView(field: field) }
            Picker("Mod",selection: field.mode) {
                Text("Sıralı").tag(SerialField.Mode.sequential)
                Text("Yığın (kes ve istifle)").tag(SerialField.Mode.stack)
            }
            if field.wrappedValue.usesSerialNumber {
                number("Başlangıç",field.start)
                number("Artış",field.step)
                Toggle("Bitiş no göster",isOn: field.showsEndNumber).toggleStyle(.checkbox)
                if field.wrappedValue.showsEndNumber {
                    HStack {
                        Text("Bitiş no")
                        TextField("Bitiş no",text: Binding(get: {
                            editingEnd == field.wrappedValue.id ? endDraft :
                                field.wrappedValue.value(at: max(1,model.serialQuantity(job: job))-1).map(String.init) ?? ""
                        },set: {
                            endDraft = $0
                            model.setSerialEnd($0,id: field.wrappedValue.id)
                        })).textFieldStyle(.roundedBorder).focused($editingEnd,equals: field.wrappedValue.id)
                    }
                    if let error = model.serialInputErrors[field.wrappedValue.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Toggle("Basamağı elle sabitle",isOn: field.digitsAreManual).toggleStyle(.checkbox)
                Stepper("Basamak: \(field.wrappedValue.digits)",value: Binding(get: { field.wrappedValue.digits },
                    set: { model.setSerialDigits($0,id: field.wrappedValue.id) }),in: 0...32)
                if let note = field.wrappedValue.digitNote(quantity: model.serialNumberedQuantity(job: job)) {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
                TextField("Önek",text: field.prefix).textFieldStyle(.roundedBorder)
                TextField("Sonek",text: field.suffix).textFieldStyle(.roundedBorder)
            } else {
                Text("Sabit içerik: aynı kod her numaralanan kopyaya basılır; Adet / fire politikası korunur.").font(.caption).foregroundStyle(.secondary)
            }
            if field.wrappedValue.kind == .text || field.wrappedValue.codeSettings.humanReadable {
                Picker("Yazı tipi",selection: field.font) {
                    ForEach(Array(Set(["Helvetica","Helvetica-Bold","Menlo-Regular","Times-Roman","Courier",field.wrappedValue.font])).sorted(),id: \.self) { Text($0).tag($0) }
                }
                TextField("Yazı tipi adı",text: field.font).textFieldStyle(.roundedBorder)
                if NSFont(name: field.wrappedValue.font,size: 12) == nil {
                    Text("Yazı tipi bulunamadı; sistem yedeği kullanılır.").font(.caption).foregroundStyle(.orange)
                }
                if field.wrappedValue.kind == .text { number("Boyut (pt)",field.size) }
                else { number("Okunabilir metin (pt)",field.codeSettings.humanFontSize) }
            }
            number("Dönüş (°)",field.rotation)
            Picker("Yüzler",selection: field.sides) {
                Text("Ön").tag(SerialField.Sides.front)
                Text("Arka").tag(SerialField.Sides.back)
                Text("Ön ve arka").tag(SerialField.Sides.both)
            }
            number("X (mm)",field.position.x)
            number("Y (mm)",field.position.y)
            if field.wrappedValue.kind == .text {
                Picker("Renk uzayı",selection: Binding(get: { field.wrappedValue.color.components.count == 4 },set: {
                    field.wrappedValue.color = $0 ? .cmyk(0,0,0,1) : .rgb(0,0,0)
                })) { Text("CMYK").tag(true); Text("RGB").tag(false) }
            } else { Text("Kod rengi: CMYK").font(.caption) }
            let names = field.wrappedValue.kind != .text || field.wrappedValue.color.components.count == 4 ? ["C","M","Y","K"] : ["R","G","B"]
            ForEach(Array(names.enumerated()),id: \.offset) { channel,name in
                number(name+" (%)",Binding(get: {
                    let components = field.wrappedValue.kind != .text && field.wrappedValue.color.components.count != 4 ? [0,0,0,1] : field.wrappedValue.color.components
                    return components.indices.contains(channel) ? components[channel]*100 : 0
                },set: { value in
                    var components = field.wrappedValue.color.components
                    if field.wrappedValue.kind != .text && components.count != 4 { components = [0,0,0,1] }
                    guard channel < components.count else { return }
                    components[channel] = value/100
                    field.wrappedValue.color = components.count == 4 ? .cmyk(components[0],components[1],components[2],components[3]) :
                        .rgb(components[0],components[1],components[2])
                }))
            }
            Text("Adet, Tekrarlı Yerleşim ile eşzamanlıdır ve her işe uygulanır. Bitiş no yalnız seçili alan üzerinden adedi belirler.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func syncEndDraft() {
        if let id = editingEnd,let field = model.editableSerialFields.first(where: { $0.id == id }) {
            endDraft = field.value(at: max(1,model.serialQuantity(job: field.jobIndex))-1).map(String.init) ?? ""
        }
    }
    private func number(_ title: String,_ value: Binding<Int64>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value: value,format: .number).frame(width: 95).textFieldStyle(.roundedBorder) }
    }
    private func number(_ title: String,_ value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value: value,format: .number.precision(.fractionLength(0...2))).frame(width: 95).textFieldStyle(.roundedBorder) }
    }
}
