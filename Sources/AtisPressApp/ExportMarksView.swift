import SwiftUI
import ImpositionCore
import PDFEngine

struct ExportMarksView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text("Çıktı İşaretleri").font(.headline)
            Toggle(model.autoLabel("Kesim işaretleri / crop marks",.exportCrop),isOn: model.autoBinding($model.project.exportMarks.crop,.exportCrop))
            Toggle(model.autoLabel("Katlama işaretleri",.exportFold),isOn: model.autoBinding($model.project.exportMarks.fold,.exportFold))
            Toggle(model.autoLabel("Taşma çizgisi",.exportBleed),isOn: model.autoBinding($model.project.exportMarks.bleed,.exportBleed))
            Toggle(model.autoLabel("Güvenli alan",.exportSafeArea),isOn: model.autoBinding($model.project.exportMarks.safeArea,.exportSafeArea))
            Toggle(model.autoLabel("Sayfa numaraları / slot etiketleri",.exportPageNumbers),isOn: model.autoBinding($model.project.exportMarks.pageNumbers,.exportPageNumbers))
            Toggle(model.autoLabel("Tabaka bilgi şeridi (iş adı, tabaka no, ön/arka)",.exportSheetInfo),isOn: model.autoBinding($model.project.exportMarks.sheetInfo,.exportSheetInfo))
            Toggle(model.autoLabel("Kesim çizgisi tam uzunlukta (artwork üzerinde)",.exportFullCut),isOn: model.autoBinding($model.project.exportMarks.fullCut,.exportFullCut))
            HStack {
                Picker(model.autoLabel("Renk",.exportColor),selection: model.autoBinding($model.project.exportMarks.color,.exportColor)) {
                    Text("Siyah (CMYK 0,0,0,100)").tag(ExportMarks.Color.black)
                    Text("Registration (100,100,100,100)").tag(ExportMarks.Color.registration)
                }
                TextField("Kalınlık (pt)",value: model.autoBinding($model.project.exportMarks.lineWidth,.exportLineWidth),format: .number).frame(width: 70)
                Text(model.autoLabel("pt",.exportLineWidth))
            }
            let warnings = Set(model.plan.sheets.flatMap { sheet in
                [sheet.front,sheet.back].flatMap { PDFExportMarkRenderer.geometry(side: $0,sheet: sheet,settings: model.project.exportMarks).warnings }
            }).sorted()
            ForEach(warnings,id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }.toggleStyle(.checkbox).padding(12).frame(width: 540)
    }
}
