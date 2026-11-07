import SwiftUI
import ImpositionCore
import PDFEngine

struct ExportMarksView: View {
    @ObservedObject var model: Workspace
    var body: some View {
        ScrollView {
        VStack(alignment: .leading,spacing: 8) {
            if model.plan.hasBlankBacks {
                if model.plan.hasBackContent {
                    Toggle("Boş arka yüzleri çıktıya ekle",isOn: Binding(get: { model.project.includeBlankBacks ?? true },set: { model.project.includeBlankBacks = $0 }))
                    Text("Çift yönlü baskı hizalaması için açık bırakın.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Arka yüz boş: çıktıya eklenmedi.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            Text("Çıktı İşaretleri").font(.headline)
            Toggle(model.autoLabel("Kesim işaretleri / crop marks",.exportCrop),isOn: model.autoBinding($model.project.exportMarks.crop,.exportCrop))
            Toggle(model.autoLabel("Katlama işaretleri",.exportFold),isOn: model.autoBinding($model.project.exportMarks.fold,.exportFold))
            Toggle(model.autoLabel("Taşma çizgisi",.exportBleed),isOn: model.autoBinding($model.project.exportMarks.bleed,.exportBleed))
            Toggle(model.autoLabel("Güvenli alan",.exportSafeArea),isOn: model.autoBinding($model.project.exportMarks.safeArea,.exportSafeArea))
            Toggle(model.autoLabel("Sayfa numaraları / slot etiketleri",.exportPageNumbers),isOn: model.autoBinding($model.project.exportMarks.pageNumbers,.exportPageNumbers))
            Toggle(model.autoLabel("Tabaka bilgi şeridi (iş adı, tabaka no, ön/arka)",.exportSheetInfo),isOn: model.autoBinding($model.project.exportMarks.sheetInfo,.exportSheetInfo))
            if model.project.exportMarks.sheetInfo {
                TextField("İş adı",text: Binding(get: { model.infoJobName },set: { model.infoJobName = $0 })).textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("İş adı",isOn: model.sheetInfoBinding(\.showJobName))
                    Toggle("Tarih",isOn: model.sheetInfoBinding(\.date))
                    Toggle("Tabaka no / toplam",isOn: model.sheetInfoBinding(\.sheetNumber))
                }
                HStack {
                    Toggle("Ön/Arka",isOn: model.sheetInfoBinding(\.side))
                    Toggle("Tabaka boyutu",isOn: model.sheetInfoBinding(\.sheetSize))
                    Toggle("Ofset/Dijital",isOn: model.sheetInfoBinding(\.production))
                }
                if let sheet = model.currentSheet {
                    let text = model.sheetInfoText(sheet: sheet,number: model.plan.sheets.prefix(model.sheetIndex).reduce(0) { $0+$1.repeatCount }+model.repetition+1,kind: model.side)
                    Text("Örnek (6 pt): "+(text.isEmpty ? "Alan seçilmedi; şerit basılmaz." : text)).font(.caption)
                    if !text.isEmpty,PDFSheetInfo.placement(text: text,side: model.currentSide ?? sheet.front,sheet: sheet,marks: model.project.exportMarks) == nil {
                        Text(PDFSheetInfo.noRoomWarning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
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
        }.toggleStyle(.checkbox).padding(12).frame(maxWidth: .infinity,alignment: .leading)
        }.frame(width: 540,height: 390)
    }
}
