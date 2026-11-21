import SwiftUI
import ImpositionCore
import PDFEngine

struct ExportMarksView: View {
    @ObservedObject var model: Workspace
    enum Scope {case all,printed,output,info,options,colorControls,registration}
    var inline = false
    var scope:Scope = .all
    @ViewBuilder var body: some View {
        if inline { fields } else { ScrollView { fields }.frame(width:540,height:390) }
    }
    private var fields:some View {
        VStack(alignment: .leading,spacing: 8) {
            if (scope == .all || scope == .options || scope == .output) && model.plan.hasBlankBacks {
                if model.plan.hasBackContent {
                    Toggle("Boş arka yüzleri çıktıya ekle",isOn: Binding(get: { model.project.includeBlankBacks ?? true },set: { model.project.includeBlankBacks = $0 })).inspectorTarget("blankBacks").settingHint("Boş arka yüzleri çıktıya ekle",SettingGuidance.detail("Boş arka yüzleri çıktıya ekle"))
                    Text("Çift yönlü baskı hizalaması için açık bırakın.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                } else {
                    Text("Arka yüz boş: çıktıya eklenmedi.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                }
                Divider()
            }
            if scope == .all || scope == .printed { Text("Çıktı İşaretleri").font(.headline) }
            if scope == .all || scope == .colorControls {
                Toggle("Renk skalası (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.colorBar,.exportColorBar)).inspectorTarget("colorBar").automaticReset(model,.exportColorBar)
            }
            if scope == .all || scope == .registration {
                Toggle("Diz işaretleri (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.registrationTargets,.exportTargets)).inspectorTarget("targets").automaticReset(model,.exportTargets)
                if scope == .all {ColorControlSizeView(model:model)}
            }
            if scope == .all || scope == .printed {
                Toggle("Kros işaretleri (çıktıya basılır)",isOn:ContextBindings(model:model).crosses)
                Toggle("Kesim işaretleri (çıktıya basılır)",isOn: ContextBindings(model:model).crop).inspectorTarget("crop").automaticReset(model,.exportCrop)
                if model.project.isBooklet { Toggle("Katlama işaretleri (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.fold,.exportFold)).inspectorTarget("fold").automaticReset(model,.exportFold) }
                Toggle("Taşma çizgisi (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.bleed,.exportBleed)).inspectorTarget("printBleed").automaticReset(model,.exportBleed)
                Toggle("Güvenli alan (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.safeArea,.exportSafeArea)).inspectorTarget("printSafe").automaticReset(model,.exportSafeArea)
                Toggle("Sayfa numaraları / yuva etiketleri (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.pageNumbers,.exportPageNumbers)).inspectorTarget("printNumbers").automaticReset(model,.exportPageNumbers)
            }
            if scope == .all || scope == .info || scope == .output {
                Toggle("Tabaka bilgi şeridi (iş adı, tabaka no, ön/arka) (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.sheetInfo,.exportSheetInfo)).inspectorTarget("sheetInfo").automaticReset(model,.exportSheetInfo)
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
                        Text("Örnek (6 pt): "+(text.isEmpty ? "Alan seçilmedi; şerit basılmaz." : text)).font(.system(size:12))
                        if !text.isEmpty,PDFSheetInfo.placement(text: text,side: model.currentSide ?? sheet.front,sheet: sheet,marks: model.project.exportMarks,kind: model.side) == nil {
                            Text(PDFSheetInfo.noRoomWarning).font(.system(size:12)).foregroundStyle(DesignSystem.warning)
                        }
                    }
                }
            }
            if scope == .all || scope == .printed {
                Toggle("Ürün üzerinde tam kesim çizgisi (çıktıya basılır)",isOn: model.autoBinding($model.project.exportMarks.fullCut,.exportFullCut)).inspectorTarget("fullCut").automaticReset(model,.exportFullCut)
                VStack(alignment:.leading,spacing:DesignSystem.Space.sm) {
                    Picker("Çizgi rengi",selection:model.autoBinding($model.project.exportMarks.color,.exportColor)) {
                        Text("Siyah").tag(ExportMarks.Color.black)
                        Text("Tüm kalıplar").tag(ExportMarks.Color.registration)
                    }.pickerStyle(.segmented).inspectorTarget("lineColor").automaticReset(model,.exportColor)
                    HStack {
                        Text("Çizgi kalınlığı")
                        Spacer()
                        DimensionInput("Çizgi kalınlığı",value:model.autoBinding($model.project.exportMarks.lineWidth,.exportLineWidth),unit:"pt",range:0.01...20,inspectorID:"lineWidth")
                    }.automaticReset(model,.exportLineWidth)
                }
            }
            let warnings = Set(model.plan.sheets.flatMap { sheet -> [String] in
                var messages: [String] = []
                if scope == .all || scope == .printed {
                    messages += [sheet.front, sheet.back].flatMap {
                        PDFExportMarkRenderer.geometry(side: $0, sheet: sheet, settings: model.project.exportMarks).warnings
                    }
                }
                if scope == .all || scope == .colorControls || scope == .registration {
                    messages += PDFColorControlRenderer.geometry(sheet: sheet, settings: model.project.exportMarks).warnings
                }
                return messages
            }).sorted()
            ForEach(warnings,id:\.self) { Text(TRFormat.presentation($0)).font(.system(size:12)).foregroundStyle(DesignSystem.warning) }
        }.toggleStyle(.switch).padding(12).frame(maxWidth: .infinity,alignment: .leading)
    }
}
