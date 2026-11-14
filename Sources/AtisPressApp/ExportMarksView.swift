import SwiftUI
import ImpositionCore
import PDFEngine

struct ExportMarksView: View {
    @ObservedObject var model: Workspace
    var inline = false
    @ViewBuilder var body: some View {
        if inline { fields } else { ScrollView { fields }.frame(width:540,height:390) }
    }
    private var fields:some View {
        VStack(alignment: .leading,spacing: 8) {
            if model.plan.hasBlankBacks {
                if model.plan.hasBackContent {
                    Toggle("Boş arka yüzleri çıktıya ekle",isOn: Binding(get: { model.project.includeBlankBacks ?? true },set: { model.project.includeBlankBacks = $0 })).settingHint("Boş arka yüzleri çıktıya ekle",SettingGuidance.detail("Boş arka yüzleri çıktıya ekle"))
                    Text("Çift yönlü baskı hizalaması için açık bırakın.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
                } else {
                    Text("Arka yüz boş: çıktıya eklenmedi.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
                }
                Divider()
            }
            Text("Çıktı İşaretleri").font(.headline)
            Toggle("Renk skalası",isOn: model.autoBinding($model.project.exportMarks.colorBar,.exportColorBar)).automaticReset(model,.exportColorBar)
            Toggle("Diz işaretleri",isOn: model.autoBinding($model.project.exportMarks.registrationTargets,.exportTargets)).automaticReset(model,.exportTargets)
            ColorControlSizeView(model: model)
            Toggle("Kesim işaretleri",isOn: model.autoBinding($model.project.exportMarks.crop,.exportCrop)).automaticReset(model,.exportCrop)
            if model.project.isBooklet { Toggle("Katlama işaretleri",isOn: model.autoBinding($model.project.exportMarks.fold,.exportFold)).automaticReset(model,.exportFold) }
            Toggle("Taşma çizgisi",isOn: model.autoBinding($model.project.exportMarks.bleed,.exportBleed)).automaticReset(model,.exportBleed)
            Toggle("Güvenli alan",isOn: model.autoBinding($model.project.exportMarks.safeArea,.exportSafeArea)).automaticReset(model,.exportSafeArea)
            Toggle("Sayfa numaraları / yuva etiketleri",isOn: model.autoBinding($model.project.exportMarks.pageNumbers,.exportPageNumbers)).automaticReset(model,.exportPageNumbers)
            Toggle("Tabaka bilgi şeridi (iş adı, tabaka no, ön/arka)",isOn: model.autoBinding($model.project.exportMarks.sheetInfo,.exportSheetInfo)).automaticReset(model,.exportSheetInfo)
            if model.project.exportMarks.sheetInfo {
                LabeledContent("İş adı") { TextField("İş adı",text: Binding(get: { model.infoJobName },set: { model.infoJobName = $0 })).textFieldStyle(.roundedBorder) }
                VStack(alignment:.leading) {
                    Toggle("İş adı",isOn: model.sheetInfoBinding(\.showJobName)).settingHint("İş adı",SettingGuidance.detail("İş adı"))
                    Toggle("Tarih",isOn: model.sheetInfoBinding(\.date)).settingHint("Tarih",SettingGuidance.detail("Tarih"))
                    Toggle("Tabaka no / toplam",isOn: model.sheetInfoBinding(\.sheetNumber)).settingHint("Tabaka no / toplam",SettingGuidance.detail("Tabaka no / toplam"))
                }
                VStack(alignment:.leading) {
                    Toggle("Ön/Arka",isOn: model.sheetInfoBinding(\.side)).settingHint("Ön/Arka",SettingGuidance.detail("Ön/Arka"))
                    Toggle("Tabaka boyutu",isOn: model.sheetInfoBinding(\.sheetSize)).settingHint("Tabaka boyutu",SettingGuidance.detail("Tabaka boyutu"))
                    Toggle("Ofset/Dijital",isOn: model.sheetInfoBinding(\.production)).settingHint("Ofset/Dijital",SettingGuidance.detail("Ofset/Dijital"))
                }
                if let sheet = model.currentSheet {
                    let text = model.sheetInfoText(sheet: sheet,number: model.plan.sheets.prefix(model.sheetIndex).reduce(0) { $0+$1.repeatCount }+model.repetition+1,kind: model.side)
                    Text("Örnek (6 pt): "+(text.isEmpty ? "Alan seçilmedi; şerit basılmaz." : text)).font(.caption)
                    if !text.isEmpty,PDFSheetInfo.placement(text: text,side: model.currentSide ?? sheet.front,sheet: sheet,marks: model.project.exportMarks,kind: model.side) == nil {
                        Text(PDFSheetInfo.noRoomWarning).font(.caption).foregroundStyle(DesignSystem.warning)
                    }
                }
            }
            Toggle("Ürün üzerinde tam kesim çizgisi",isOn: model.autoBinding($model.project.exportMarks.fullCut,.exportFullCut)).automaticReset(model,.exportFullCut)
            VStack(alignment:.leading,spacing:DesignSystem.Space.sm) {
                Picker("Çizgi rengi",selection:model.autoBinding($model.project.exportMarks.color,.exportColor)) {
                    Text("Siyah").tag(ExportMarks.Color.black)
                    Text("Tüm kalıplar").tag(ExportMarks.Color.registration)
                }.pickerStyle(.segmented).automaticReset(model,.exportColor)
                HStack {
                    Text("Çizgi kalınlığı")
                    Spacer()
                    DimensionInput("Çizgi kalınlığı",value:model.autoBinding($model.project.exportMarks.lineWidth,.exportLineWidth),unit:"pt",range:0.01...20)
                }.automaticReset(model,.exportLineWidth)
            }
            let warnings = Set(model.plan.sheets.flatMap { sheet in
                [sheet.front,sheet.back].flatMap { PDFExportMarkRenderer.geometry(side: $0,sheet: sheet,settings: model.project.exportMarks).warnings } + PDFColorControlRenderer.geometry(sheet: sheet,settings: model.project.exportMarks).warnings
            }).sorted()
            ForEach(warnings,id: \.self) { Text(TRFormat.presentation($0)).font(.caption).foregroundStyle(DesignSystem.warning) }
        }.toggleStyle(.switch).padding(12).frame(maxWidth: .infinity,alignment: .leading)
    }
}
