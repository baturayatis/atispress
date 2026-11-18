import SwiftUI
import ImpositionCore
import PDFEngine

struct InternalCutMarksView: View {
    @ObservedObject var model: Workspace
    @State private var selectedFront: Int?

    var body: some View {
        GroupBox("İç Kesim İşaretleri") {
            VStack(alignment: .leading, spacing: 8) {
                if model.project.binding == .gang {
                    let jobs = model.project.gang?.jobs ?? []
                    if let job = model.selectedGangJob {
                        Picker("İş", selection: Binding(
                            get: { model.selectedGangJob?.id ?? job.id },
                            set: { model.selectedGangJobID = $0 }
                        )) {
                            ForEach(jobs) { Text($0.name).tag($0.id) }
                        }
                        editor(Binding(
                            get: { model.project.gang?.jobs.first { $0.id == job.id }?.internalCuts ?? InternalCutMarks() },
                            set: { value in model.editGangJob(job.id) { $0.internalCuts = value } }
                        ), size: job.front.trimSize)
                    }
                } else if model.project.binding == .stepAndRepeat {
                    let jobs = model.project.repeatJobs
                    if let job = jobs.first(where: { $0.front.number == selectedFront }) ?? jobs.first {
                        Picker("İş", selection: Binding(
                            get: { job.front.number }, set: { selectedFront = $0 }
                        )) {
                            ForEach(jobs, id: \.front.number) { item in
                                Text(item.back.map { "Sayfa \(item.front.number) / \($0.number)" } ?? "Sayfa \(item.front.number)")
                                    .tag(item.front.number)
                            }
                        }
                        editor(settings(job.front.number), size: job.front.trimSize)
                    }
                } else if let page = model.project.pages.first {
                    editor(settings(0), size: page.trimSize)
                }
                if let sheet = model.currentSheet, let side = model.currentSide,
                   side.marks.contains(where: { $0.kind == .internalCut }) {
                    let geometry = PDFExportMarkRenderer.geometry(side: side, sheet: sheet, settings: cutExportMarks)
                    if let warning = geometry.warnings.first {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                    }
                }
            }.padding(5)
        }.disabled(model.project.pages.isEmpty && model.project.gang?.jobs.isEmpty != false)
    }

    private var cutExportMarks: ExportMarks {
        var marks = ExportMarks.none
        marks.lineWidth = model.project.exportMarks.lineWidth
        return marks
    }

    private func settings(_ key: Int) -> Binding<InternalCutMarks> {
        Binding(
            get: { model.project.internalCutJobs?[key] ?? InternalCutMarks() },
            set: { value in
                var jobs = model.project.internalCutJobs ?? [:]
                jobs[key] = value
                model.project.internalCutJobs = jobs
            }
        )
    }

    private func editor(_ settings: Binding<InternalCutMarks>, size: Size) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            direction("Yatay kesim", inspectorID: "horizontalCut", from: "Alt kenardan", length: size.height, value: settings.horizontal)
            direction("Dikey kesim", inspectorID: "verticalCut", from: "Sol kenardan", length: size.width, value: settings.vertical)
        }
    }

    private func direction(_ title: String, inspectorID: String, from edge: String, length: Double,
                           value: Binding<InternalCutMarks.Direction>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(title, isOn: value.enabled).inspectorTarget(inspectorID)
            if value.wrappedValue.enabled {
                Picker("Konum", selection: Binding(
                    get: { value.wrappedValue.position },
                    set: { position in
                        var direction = value.wrappedValue
                        direction.position = position
                        if position == .custom && direction.offsets.isEmpty { direction.offsets = [length / 2] }
                        value.wrappedValue = direction
                    }
                )) {
                    Text("Orta (%50)").tag(InternalCutMarks.Direction.Position.center)
                    Text("Özel (mm)").tag(InternalCutMarks.Direction.Position.custom)
                }.pickerStyle(.segmented)
                if value.wrappedValue.position == .custom {
                    Text(edge).font(.caption)
                    let offsets = value.wrappedValue.offsets
                    ForEach(offsets.indices, id: \.self) { index in
                        HStack {
                            DimensionInput("\(title) \(index + 1)", value: Binding(
                                get: { value.wrappedValue.offsets.indices.contains(index) ? value.wrappedValue.offsets[index] : 0 },
                                set: { new in
                                    guard value.wrappedValue.offsets.indices.contains(index) else { return }
                                    value.wrappedValue.offsets[index] = new
                                }
                            ), range: 0...10000)
                            Button(role: .destructive) { value.wrappedValue.offsets.remove(at: index) } label: {
                                Image(systemName: "minus.circle")
                            }.accessibilityLabel("\(title) \(index + 1) konumunu sil")
                        }
                    }
                    Button("Kesim konumu ekle") {
                        let fractions = (1...64).map { length * Double($0) / 65 }
                        let position = offsets.isEmpty ? length / 2 : fractions.first { candidate in
                            !offsets.contains { abs($0 - candidate) < 0.001 }
                        } ?? length / 2
                        value.wrappedValue.offsets.append(position)
                    }.disabled(offsets.count >= 32)
                }
            }
        }
    }
}
