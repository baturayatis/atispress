import SwiftUI
import ImpositionCore
import PDFEngine

struct SheetInfoInspectorView:View {
    @ObservedObject var model:Workspace
    var body:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.md) {
            Toggle("Bilgi şeridini çıktıya ekle",isOn:model.autoBinding($model.project.exportMarks.sheetInfo,.exportSheetInfo)).automaticReset(model,.exportSheetInfo)
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
        }
    }
}
