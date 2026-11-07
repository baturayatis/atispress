import SwiftUI
import ImpositionCore
import PDFEngine

struct ExportMarksView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text("Çıktı İşaretleri").font(.headline)
            Toggle("Kesim işaretleri / crop marks",isOn: $model.project.exportMarks.crop)
            Toggle("Katlama işaretleri",isOn: $model.project.exportMarks.fold)
            Toggle("Taşma çizgisi",isOn: $model.project.exportMarks.bleed)
            Toggle("Güvenli alan",isOn: $model.project.exportMarks.safeArea)
            Toggle("Sayfa numaraları / slot etiketleri",isOn: $model.project.exportMarks.pageNumbers)
            Toggle("Tabaka bilgi şeridi (iş adı, tabaka no, ön/arka)",isOn: $model.project.exportMarks.sheetInfo)
            Toggle("Kesim çizgisi tam uzunlukta (artwork üzerinde)",isOn: $model.project.exportMarks.fullCut)
            HStack {
                Picker("Renk",selection: $model.project.exportMarks.color) {
                    Text("Siyah (CMYK 0,0,0,100)").tag(ExportMarks.Color.black)
                    Text("Registration (100,100,100,100)").tag(ExportMarks.Color.registration)
                }
                TextField("Kalınlık (pt)",value: $model.project.exportMarks.lineWidth,format: .number).frame(width: 70)
                Text("pt")
            }
            let warnings = Set(model.plan.sheets.flatMap { sheet in
                [sheet.front,sheet.back].flatMap { PDFExportMarkRenderer.geometry(side: $0,sheet: sheet,settings: model.project.exportMarks).warnings }
            }).sorted()
            ForEach(warnings,id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }.toggleStyle(.checkbox).padding(12).frame(width: 540)
    }
}
