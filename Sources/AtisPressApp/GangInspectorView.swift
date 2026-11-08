import SwiftUI
import ImpositionCore

struct GangInspectorView: View {
    @ObservedObject var model: Workspace
    private func binding<T>(_ job: GangJob,_ key: WritableKeyPath<GangJob,T>) -> Binding<T> {
        Binding(get: { model.project.gang?.jobs.first { $0.id==job.id }?[keyPath:key] ?? job[keyPath:key] },set: { value in model.editGangJob(job.id) { $0[keyPath:key] = value } })
    }
    var body: some View {
        GroupBox("Karışık iş") {
            VStack(alignment:.leading,spacing:9) {
                Button("PDF ekle…",action:model.chooseGangPDFs)
                Picker("Düzen",selection:Binding(get: { model.project.gang?.mode ?? .automatic },set: { value in
                    if value == .manual { model.manualGang() } else { model.project.gang?.mode = .automatic }
                })) {
                    Text("Otomatik giyotin").tag(GangSettings.Mode.automatic)
                    Text("Elle yerleştir").tag(GangSettings.Mode.manual)
                }
                Text("Her iş bir dikdörtgen ızgara bloğudur. Bitişik kesimde boşluk 0; aralıklı düzende boşluk en az 2 × taşma olmalı.").font(.caption).foregroundStyle(.secondary)
                if let job = model.selectedGangJob {
                    TextField("İş adı",text:binding(job,\.name))
                    Text("\(job.front.trimSize.width,specifier:"%.1f") × \(job.front.trimSize.height,specifier:"%.1f") mm · PDF kesim ölçüsü").font(.caption)
                    let pages = model.gangSourcePages(job.sourceID)
                    Picker("Ön sayfa",selection:Binding(get: { job.front.number },set: { n in if let p = pages.first(where: { $0.number==n }) { model.editGangJob(job.id) { $0.front = p } } })) {
                        ForEach(Array(pages.enumerated()),id:\.element.number) { i,p in Text("\(i+1)").tag(p.number) }
                    }
                    Picker("Arka sayfa",selection:Binding(get: { job.back?.number ?? 0 },set: { n in model.editGangJob(job.id) { $0.back = pages.first { $0.number==n } } })) {
                        Text("Yok — tek yüz").tag(0)
                        ForEach(Array(pages.enumerated()),id:\.element.number) { i,p in Text("\(i+1)").tag(p.number) }
                    }
                    Toggle("90° döndürmeye izin ver",isOn:binding(job,\.allowRotation))
                    HStack { Text("Taşma (mm)"); TextField("Taşma",value:binding(job,\.bleed),format:.number) }
                    HStack { Text("Önizleme rengi"); Slider(value:binding(job,\.tint),in:0...1) }
                    HStack {
                        Button("İşi çoğalt") {
                            guard (model.project.gang?.jobs.count ?? 0)<8 else { return }
                            var copy = job; copy.id = UUID(); copy.name += " kopya"; copy.tint = (Double(model.project.gang?.jobs.count ?? 0)*0.61803398875+0.12).truncatingRemainder(dividingBy:1)
                            copy.serialFields = copy.serialFields.map { var f = $0; f.id = UUID(); return f }
                            model.project.gang?.jobs.append(copy); model.selectedGangJobID = copy.id
                            model.project.gang?.mode = .automatic
                        }
                        Button("İşi sil") { model.removeGangJob(job.id) }
                    }
                }
                if model.project.gang?.mode == .manual { manualControls }
            }.textFieldStyle(.roundedBorder).padding(5)
        }
    }
    @ViewBuilder private var manualControls: some View {
        let blocks = model.project.gang?.blocks ?? []
        Picker("Blok",selection:Binding(get: { model.selectedGangBlockID ?? blocks.first?.id },set: { model.selectedGangBlockID = $0 })) {
            ForEach(Array(blocks.enumerated()),id:\.element.id) { i,b in Text("Blok \(i+1)").tag(Optional(b.id)) }
        }
        if let block = blocks.first(where: { $0.id==model.selectedGangBlockID }) ?? blocks.first {
            let value = Binding(get: { model.project.gang?.blocks.first { $0.id==block.id } ?? block },set: { b in
                if let i = model.project.gang?.blocks.firstIndex(where: { $0.id==block.id }) { model.project.gang?.blocks[i] = b }
            })
            HStack { Text("X (mm)"); TextField("X",value:value.origin.x,format:.number); Text("Y"); TextField("Y",value:value.origin.y,format:.number) }
            HStack { Text("Sütun"); TextField("Sütun",value:value.columns,format:.number); Text("Satır"); TextField("Satır",value:value.rows,format:.number) }
            Toggle("Blok 90°",isOn:value.rotated)
            HStack {
                Button("Blok çoğalt") { var b = block; b.id = UUID(); b.origin.x += 10; b.origin.y += 10; model.project.gang?.blocks.append(b); model.selectedGangBlockID = b.id }
                Button("Blok sil") { model.project.gang?.blocks.removeAll { $0.id==block.id }; model.selectedGangBlockID = model.project.gang?.blocks.first?.id }
            }
        }
        Text("Blokları önizlemede sürükleyin (1 mm). Çakışma ve kesilemeyen düzen kırmızı uyarıdır; konumlar kendiliğinden değiştirilmez.").font(.caption).foregroundStyle(.secondary)
    }
}

struct GangSidebarView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text("Karışık İşler").font(.headline); Spacer(); Button("PDF ekle…",action:model.chooseGangPDFs) }.padding(10)
            ForEach(model.gangAssets,id:\.saved.id) { asset in Text(asset.saved.reference.fileName).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if let layout = model.currentSheet?.gangLayout { Text(layout.summary).font(.callout).padding(.horizontal) }
            List(selection:$model.selectedGangJobID) {
                ForEach(model.project.gang?.jobs ?? []) { job in
                    VStack(alignment:.leading,spacing:5) {
                        HStack { Circle().fill(Color(hue:job.tint,saturation:0.65,brightness:0.8)).frame(width:10,height:10); Text(job.name).fontWeight(.medium) }
                        Text("Adet \(job.quantity) + fire \(job.waste.quantities(for:job.quantity)?.waste ?? 0) · \(job.back == nil ? "Tek yüz" : "Çift yüz")").font(.caption)
                        if let result = model.currentSheet?.gangLayout?.jobs.first(where: { $0.job.id==job.id }) {
                            Text("\(result.copiesPerSheet) adet/tabaka · Fazla: \(result.surplus) adet").font(.caption)
                            ForEach(result.serialPlan.fields) { field in Text("Seri: \(result.serialPlan.range(field:field,repetition:model.repetition) ?? "—")").font(.caption) }
                        }
                    }.tag(job.id)
                }
            }.listStyle(.sidebar)
            if let sheet = model.currentSheet {
                Stepper("Tabaka \(model.repetition+1) / \(sheet.repeatCount)",value:$model.repetition,in:0...max(0,sheet.repeatCount-1)).padding(.horizontal)
                // Bounded visible window; quantities never allocate rows or serial codes eagerly.
                List {
                    ForEach(max(0,model.repetition-20)..<min(sheet.repeatCount,model.repetition+21),id:\.self) { r in
                        VStack(alignment:.leading,spacing:3) {
                            Button("Tabaka \(r+1)") { model.repetition = r }.buttonStyle(.borderless)
                            ForEach(sheet.gangLayout?.jobs ?? [],id:\.job.id) { job in
                                if let field = job.serialPlan.fields.first {
                                    Text(job.job.name+": "+(job.serialPlan.range(field:field,repetition:r) ?? "Numarasız")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxHeight:200)
            }
        }.onChange(of:model.selectedGangJobID) { _,_ in
            if !model.editableSerialFields.contains(where: { $0.id==model.selectedSerialID }) { model.selectedSerialID = nil }
            if model.project.gang?.blocks.first(where: { $0.id==model.selectedGangBlockID })?.jobID != model.selectedGangJobID {
                model.selectedGangBlockID = model.project.gang?.blocks.first { $0.jobID==model.selectedGangJobID }?.id
            }
        }
    }
}
