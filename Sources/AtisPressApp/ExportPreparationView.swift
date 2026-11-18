import SwiftUI

struct ExportPreparationView: View {
    @ObservedObject var model:Workspace
    @State private var details = false
    @State private var acknowledgedBacks=false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("PDF’i Hazırla").font(.title2.bold())
            Text(model.exportPreparationSummary).font(.callout).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(DesignSystem.workspace,in:RoundedRectangle(cornerRadius:8))
            Text("Hazır seçimler yalnız çıktı işaretlerini değiştirir. Açılışta mevcut tercihleriniz korunur.").foregroundStyle(DesignSystem.muted)
            HStack {
                ForEach(ExportPreset.allCases,id:\.self) { preset in
                    Button(preset.rawValue) { model.project.exportMarks = preset.applying(to:model.project.exportMarks) }
                }
                SettingHelp(title:"Çıktı hazır seçimleri",detail:"Matbaaya gönder: kesim, katlama, bilgi şeridi, renk skalası ve dizler. Dijital baskı: kesim. Kontrol çıktısı: kesim, katlama, taşma, güvenli alan, sayfa numaraları ve bilgi şeridi. Mevcut çizgi rengi, kalınlığı ve ölçüler korunur; bu seçimler PDF/X dönüşümü yapmaz.")
            }
            DisclosureGroup("İşaret ayrıntıları",isExpanded:$details) { ExportMarksView(model:model) }
            if model.requiresBacklessConfirmation {Toggle("Arka yüz yok. Bu şekilde dışa aktarmayı onaylıyorum.",isOn:$acknowledgedBacks)}
            Text(model.statusSummary).font(.caption)
            HStack {
                Button("İptal") { model.preparingExport = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Menu("Diğer çıktı") { Button("Her tabaka — ayrı PDF…") { proceed(perSheet:true) } }.disabled(model.requiresBacklessConfirmation && !acknowledgedBacks)
                Button("Bütün işi dışa aktar…") { proceed(perSheet:false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.requiresBacklessConfirmation && !acknowledgedBacks)
            }
        }.padding(22).frame(width:620)
    }
    private func proceed(perSheet:Bool) {
        guard !model.requiresBacklessConfirmation || acknowledgedBacks else {return}
        model.allowBacklessExportOnce=acknowledgedBacks
        model.preparingExport = false
        DispatchQueue.main.async { model.chooseExport(perSheet:perSheet) }
    }
}

extension Workspace {
    var exportPreparationSummary:String {
        let sizes = Array(Set(plan.sheets.map { TRFormat.size($0.size.width,$0.size.height) })).sorted().joined(separator:" / ")
        let m = project.exportMarks
        let marks = [(m.crop,"kesim"),(m.fold,"katlama"),(m.bleed,"taşma"),(m.safeArea,"güvenli alan"),(m.pageNumbers,"sayfa no"),(m.sheetInfo,"bilgi şeridi"),(m.fullCut,"tam kesim"),(m.colorBar,"renk skalası"),(m.registrationTargets,"diz")].filter(\.0).map(\.1).joined(separator:", ")
        return "\(plan.totalPressSheets) tabaka · \(sizes) · \(plan.hasBackContent ? "ön ve arka" : "yalnız ön") · İşaretler: \(marks.isEmpty ? "yok" : marks) · \(workflowIssues.filter { $0.severity == .warning }.count) uyarı" + (requiresBacklessConfirmation ? "\nArka yüz yok":"") + (showsMissingBleedWarning ? "\n"+Self.missingBleedWarning : "") + (hiddenSourceGuideCount>0 ? "\n\(hiddenSourceGuideCount) kılavuz çizgisi gizlendi" : "")
    }
}
