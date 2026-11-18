import SwiftUI
import ImpositionCore
import PDFEngine

struct ImageColorInspector: View {
    @ObservedObject var model: Workspace
    @State private var frontPage: Int?

    private struct InspectionKey: Equatable {
        let source: UUID?
        let pages: Set<Int>
        let profileID: String?
    }

    @State private var inspectedKey: InspectionKey?
    @State private var inspection: PDFColorInspection?
    @State private var profiles: [PDFCMYKProfileOption]?

    private var inspectionKey: InspectionKey {
        let gangID = model.project.binding == .gang ? model.selectedGangJob?.id : nil
        let repeatPage = model.project.binding == .stepAndRepeat
            ? model.project.repeatJobs.first(where: { $0.front.number == frontPage })?.front.number ??
                model.project.repeatJobs.first?.front.number
            : nil
        let slots = model.plan.sheets
            .filter { repeatPage == nil || $0.repeatLayout?.frontPageNumber == repeatPage }
            .flatMap { $0.front.slots + $0.back.slots }
            .filter { gangID == nil || $0.gangJobID == gangID }
        let profileID = gangID == nil ? model.project.imageColorJobs?[repeatPage ?? 0]?.cmykProfileID
            : model.selectedGangJob?.imageColor?.cmykProfileID
        return InspectionKey(source: model.source?.id, pages: Set(slots.compactMap(\.sourcePageNumber)), profileID: profileID)
    }

    var body: some View {
        let key = inspectionKey
        let current = inspectedKey == key ? inspection : nil
        return groupBoxContent(current: current, key: key)
            .task(id: key) { await inspect(key) }
            .task { await loadProfiles() }
    }

    private func groupBoxContent(current: PDFColorInspection?, key: InspectionKey) -> some View {
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
                    ), inspection: current)
                } else if model.project.binding == .stepAndRepeat,
                          let job = model.project.repeatJobs.first(where: { $0.front.number == frontPage }) ?? model.project.repeatJobs.first {
                    Picker("İş", selection: Binding(get: { job.front.number }, set: selectFront)) {
                        ForEach(model.project.repeatJobs, id: \.front.number) { row in
                            Text(row.back.map { "Sayfa \(row.front.number) / \($0.number)" } ?? "Sayfa \(row.front.number)")
                                .tag(row.front.number)
                        }
                    }
                    controls(settings(job.front.number), inspection: current)
                } else if !model.project.pages.isEmpty {
                    controls(settings(0), inspection: current)
                }
                Picker("Önizleme", selection: $model.previewOriginalColors) {
                    Text("Özgün").tag(true)
                    Text("Düzenlenmiş").tag(false)
                }.pickerStyle(.segmented)
                Text("PDF çıktısı düzenlenmiş görünümü kullanır.").font(.caption)
                if model.planning || model.preparingColorPreview {
                    ProgressView("Renk önizlemesi hazırlanıyor…").controlSize(.small)
                }
                if let current {
                    Text("Düzenlenebilir görsel nesnesi: \(current.editableCount)").font(.caption)
                } else if !key.pages.isEmpty {
                    ProgressView("PDF görselleri inceleniyor…").controlSize(.small)
                }
                let warnings = Set((current?.warnings ?? []) + (model.colorVariants?.warnings ?? []))
                ForEach(warnings.sorted(), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }.padding(5)
        }
    }

    private func inspect(_ key: InspectionKey) async {
        guard let source = model.source, source.id == key.source, !key.pages.isEmpty else { return }
        let worker = Task.detached(priority: .userInitiated) {
            try PDFColorVariants.inspect(source: source, pages: key.pages, cmykProfileID: key.profileID)
        }
        let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { return }
        inspection = try? result.get()
        inspectedKey = key
    }

    private func loadProfiles() async {
        let worker = Task.detached(priority: .userInitiated) { PDFCMYKProfiles.installed() }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        if !Task.isCancelled { profiles = result }
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

    private func controls(_ value: Binding<ImageColorAdjustment>, inspection: PDFColorInspection?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if (inspection?.unprofiledCMYKCount ?? 0) > 0 || value.wrappedValue.cmykProfileID != nil {
                profilePicker(value.cmykProfileID)
            }
            slider("Parlaklık", value: value.brightness, range: -0.5...0.5).disabled((inspection?.editableCount ?? 0) == 0)
            slider("Kontrast", value: value.contrast, range: 0...2).disabled((inspection?.editableCount ?? 0) == 0)
            slider("Doygunluk", value: value.saturation, range: 0...2).disabled((inspection?.saturationCount ?? 0) == 0)
            Button("Sıfırla") { value.wrappedValue = ImageColorAdjustment() }.disabled(value.wrappedValue.isNeutral)
        }
    }

    private func profilePicker(_ selection: Binding<String?>) -> some View {
        let options = profiles ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Profilsiz CMYK için ICC", selection: selection) {
                Text("Profil atanmasın").tag(nil as String?)
                ForEach(options) { option in
                    let duplicateName = options.contains { $0.id != option.id && $0.name == option.name }
                    Text(duplicateName ? "\(option.name) (\(option.id.prefix(8)))" : option.name).tag(Optional(option.id))
                }
                if let saved = selection.wrappedValue, !options.contains(where: { $0.id == saved }) {
                    Text(profiles == nil ? "Kayıtlı profil aranıyor…" : "Kayıtlı profil kullanılamıyor").tag(Optional(saved))
                }
            }
            .help("Seçilen yüklü ICC profili yalnız gömülü profili olmayan uygun CMYK görsellere atanır.")
            if profiles?.isEmpty == true {
                Text("Çift yönlü dönüşümü destekleyen yüklü CMYK baskı profili bulunamadı.").font(.caption)
            }
            if selection.wrappedValue != nil {
                Text("Profil ataması renk görünümünü değiştirebilir. Renk ayarları toplam mürekkep kaplamasını (TAC) değiştirebilir.").font(.caption)
            }
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
