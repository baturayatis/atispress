import SwiftUI
import ImpositionCore

struct TeamInspectorView: View {
    @ObservedObject var model: Workspace

    var body: some View {
        GroupBox("Takım Düzeni") {
            VStack(alignment: .leading, spacing: 8) {
                if model.project.sourcePreparation?.separation != nil {
                    Button("Bölgeleri ve yüzleri düzenle…") { model.showingArtworkSeparation = true }
                } else {
                    Picker("Baskı", selection: Binding(get: { model.project.team?.duplex ?? false }, set: model.setTeamDuplex)) {
                        Text("Tek yüz").tag(false)
                        Text("Çift yüz").tag(true)
                    }.pickerStyle(.segmented)
                }
                Toggle("90° döndürmeye izin ver", isOn: Binding(
                    get: { model.project.team?.allowRotation ?? true },
                    set: { value in
                        model.project.team?.allowRotation = value
                        model.project.team?.manualLayouts = nil
                    }))
                if model.project.sourcePreparation?.separation == nil, model.project.team?.duplex == true, let job = model.selectedGangJob {
                    pagePicker(job, side: .front)
                    pagePicker(job, side: .back)
                    Button("Sıralı eşle (1–2, 3–4…)") { model.setTeamDuplex(true) }
                }
                Picker("Yerleşim", selection: Binding(get: { model.project.team?.manualLayouts != nil }, set: { manual in
                    if manual { model.manualGang() } else { model.project.team?.manualLayouts = nil }
                })) {
                    Text("Otomatik").tag(false)
                    Text("Elle yerleştir").tag(true)
                }.pickerStyle(.segmented)
                if let plates = model.project.team?.manualLayouts, plates.indices.contains(model.sheetIndex) {
                    placementControls(plates[model.sheetIndex])
                }
            }.padding(5)
        }
    }

    private func pagePicker(_ job: GangJob, side: SideKind) -> some View {
        let number = side == .front ? job.front.number : job.back?.number ?? 0
        let jobs = model.project.gang?.jobs ?? []
        let pages = jobs.flatMap { other -> [Int] in
            let back = other.back?.number ?? 0
            if side == .front { return [other.front.number] + (back > 0 ? [back] : []) }
            return number == 0 ? [back] : [other.front.number, back]
        }
        return Picker(side == .front ? "Ön sayfayla değiştir" : "Arka sayfayla değiştir", selection: Binding(
            get: { number },
            set: { model.swapTeamPage(jobID: job.id, side: side, with: $0) }
        )) {
            ForEach(Set(pages).sorted(), id: \.self) { page in
                Text(page == 0 ? "Boş arka" : "Sayfa \(page)").tag(page)
            }
        }
    }

    @ViewBuilder private func placementControls(_ blocks: [GangBlock]) -> some View {
        Picker("Blok", selection: Binding(
            get: { blocks.first(where: { $0.id == model.selectedGangBlockID })?.id ?? blocks.first?.id },
            set: { model.selectedGangBlockID = $0 }
        )) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                Text("Blok \(index + 1)").tag(Optional(block.id))
            }
        }
        if let block = blocks.first(where: { $0.id == model.selectedGangBlockID }) ?? blocks.first {
            let binding = Binding(get: { block }, set: { updated in model.editTeamBlock(block.id) { $0 = updated } })
            HStack {
                Text("X")
                DimensionInput("X", value: binding.origin.x)
                Text("Y")
                DimensionInput("Y", value: binding.origin.y)
            }
            if model.project.team?.allowRotation == true {
                Toggle("Bloğu 90° döndür", isOn: binding.rotated)
            }
            Menu("Sayfa yerleşimini değiştir") {
                ForEach((model.project.gang?.jobs ?? []).filter { $0.id != block.jobID }) { job in
                    Button(job.name) { model.swapTeamPlacements(block.jobID, job.id) }
                }
            }
            Menu("Blok konumlarını değiştir") {
                ForEach(Array(blocks.enumerated()).filter { $0.element.id != block.id }, id: \.element.id) { index, other in
                    Button("Blok \(index + 1)") { model.swapTeamBlocks(block.id, other.id) }
                }
            }
        }
    }
}
