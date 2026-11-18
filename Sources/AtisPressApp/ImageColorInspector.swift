import SwiftUI
import ImpositionCore

struct ImageColorInspector: View {
    @ObservedObject var model: Workspace
    @State private var frontPage: Int?

    var body: some View {
        GroupBox("Baskı Öncesi Renk Düzenleme") {
            VStack(alignment: .leading, spacing: 8) {
                if model.project.binding == .gang, let job = model.selectedGangJob {
                    Picker("İş", selection: Binding(
                        get: { model.selectedGangJob?.id ?? job.id },
                        set: { id in
                            model.selectedGangJobID = id
                            if let index = model.plan.sheets.firstIndex(where: { $0.gangLayout?.jobs.contains { $0.job.id == id } == true }) {
                                model.selectPreviewSheet(index)
                            }
                        }
                    )) {
                        ForEach(model.project.gang?.jobs ?? []) { Text($0.name).tag($0.id) }
                    }
                    controls(Binding(
                        get: { model.project.gang?.jobs.first { $0.id == job.id }?.imageColor ?? ImageColorAdjustment() },
                        set: { value in model.editGangJob(job.id) { $0.imageColor = value.isNeutral ? nil : value } }
                    ))
                } else if model.project.binding == .stepAndRepeat,
                          let job = model.project.repeatJobs.first(where: { $0.front.number == frontPage }) ?? model.project.repeatJobs.first {
                    Picker("İş", selection: Binding(get: { job.front.number }, set: selectFront)) {
                        ForEach(model.project.repeatJobs, id: \.front.number) { row in
                            Text(row.back.map { "Sayfa \(row.front.number) / \($0.number)" } ?? "Sayfa \(row.front.number)")
                                .tag(row.front.number)
                        }
                    }
                    controls(settings(job.front.number))
                } else if !model.project.pages.isEmpty {
                    controls(settings(0))
                }
                Picker("Önizleme", selection: $model.previewOriginalColors) {
                    Text("Özgün").tag(true)
                    Text("Düzenlenmiş").tag(false)
                }.pickerStyle(.segmented)
                Text("PDF çıktısı düzenlenmiş görünümü kullanır.").font(.caption)
                if model.planning || model.preparingColorPreview {
                    ProgressView("Renk önizlemesi hazırlanıyor…").controlSize(.small)
                }
                ForEach(model.colorVariants?.warnings ?? [], id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }.padding(5)
        }
    }

    private func selectFront(_ number: Int) {
        frontPage = number
        if let index = model.plan.sheets.firstIndex(where: { $0.repeatLayout?.frontPageNumber == number }) {
            model.selectPreviewSheet(index)
        }
    }

    private func settings(_ job: Int) -> Binding<ImageColorAdjustment> {
        Binding(get: { model.project.imageColorJobs?[job] ?? ImageColorAdjustment() }, set: { value in
            var jobs = model.project.imageColorJobs ?? [:]
            jobs[job] = value.isNeutral ? nil : value
            model.project.imageColorJobs = jobs.isEmpty ? nil : jobs
        })
    }

    private func controls(_ value: Binding<ImageColorAdjustment>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            slider("Parlaklık", value: value.brightness, range: -0.5...0.5)
            slider("Kontrast", value: value.contrast, range: 0...2)
            slider("Doygunluk", value: value.saturation, range: 0...2)
            Button("Sıfırla") { value.wrappedValue = ImageColorAdjustment() }.disabled(value.wrappedValue.isNeutral)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0)).locale(TRFormat.locale))).monospacedDigit().foregroundStyle(.secondary)
            }.font(.callout)
            Slider(value: value, in: range, step: 0.01) { Text(title) }.labelsHidden()
        }
    }
}
