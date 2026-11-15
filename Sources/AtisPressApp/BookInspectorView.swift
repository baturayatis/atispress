import SwiftUI
import ImpositionCore

struct BookInspectorView: View {
    @ObservedObject var model: Workspace
    private var book: Binding<BookSettings> { $model.bookSettings }
    private var info: BookSheetInfo? { model.plan.sheets.compactMap(\.bookInfo).first }
    var body: some View {
        GroupBox("Kitap: kapak, sırt ve creep") {
            VStack(alignment:.leading,spacing:10) {
                if model.project.book == nil {
                    Text("Mevcut forma düzeni korunuyor. Kapak, sırt ve creep için ölçülmüş kâğıt bilgileriyle kitap ayarlarını açın.").font(.caption)
                    Button("Kitap ayarlarını aç",action:model.enableBookSettings)
                } else {
                    coverControls
                    PaperCaliperEditor(model:model,title:"İç kâğıt",paper:book.interiorPaper)
                    PaperCaliperEditor(model:model,title:"Kapak kâğıdı",paper:book.coverPaper)
                    if model.project.binding == .perfectBound { spineControls }
                    if model.project.binding == .saddleStitch || model.bookSettings.creepEnabled { creepControls }
                    if let info { Text(TRFormat.presentation(info.summary)).font(.caption).textSelection(.enabled) }
                    HStack {
                        Button("Kapak önizle") { model.showBookSection(.cover) }
                        Button("İç sayfalar") { model.showBookSection(.interior) }
                    }
                }
            }.padding(5).textFieldStyle(.roundedBorder)
        }
    }
    private var coverControls: some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("Kapak modu",selection:Binding(get:{ model.project.coverMode },set:model.setCoverMode)) {
                Text("Dahil").tag(CoverMode.included)
                Text("Ayrı bas").tag(CoverMode.excluded)
                Text("Ayrı PDF").tag(CoverMode.separate)
            }.pickerStyle(.segmented).inspectorSetting(model,"Kapak modu",SettingGuidance.detail("Kapak modu"))
            if model.project.coverMode == .included {
                Text("İlk iki / son iki sayfa otomatik kapaktır. Seçilen kapak yüzleri iç bloktan ayrılır ve bağımsız basılır.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
            }
            if model.project.coverMode == .separate {
                if model.project.sourcePreparation?.split == nil {Button("Kapak PDF yükle…",action:model.chooseCoverPDF).disabled(model.source == nil || model.loading)}
                if let id = model.bookSettings.coverSourceID,let asset = model.gangAssets.first(where:{ $0.saved.id==id }) {
                    Text(asset.saved.reference.fileName).font(.caption)
                }
                Picker("PDF biçimi",selection:book.coverArtwork) {
                    Text("Tek yüzler").tag(BookSettings.CoverArtwork.panels)
                    Text("Hazır açılım (dış / iç)").tag(BookSettings.CoverArtwork.spread)
                }.pickerStyle(.segmented).inspectorSetting(model,"PDF biçimi",SettingGuidance.detail("PDF biçimi"))
            }
            if model.project.coverMode == .separate && model.bookSettings.coverArtwork == .spread {
                pagePicker("Dış açılım",\.front)
                pagePicker("İç açılım",\.insideFront,allowBlank:true)
                Text("Açılım PDF’si ölçeklenmez. Ölçü farkı tam sayılarla bildirilir; baskı içeriği hesaplanan açılıma kırpılır.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
            } else {
                pagePicker("Ön kapak",\.front)
                pagePicker("İç ön",\.insideFront,allowBlank:true)
                pagePicker("İç arka",\.insideBack,allowBlank:true)
                pagePicker("Arka kapak",\.back)
                if model.project.coverMode == .excluded {
                    Button("İlk / son kapak yüzlerini seç") {
                        let pages = model.bookCoverDomain
                        guard pages.count>=4 else { return }
                        var s = CoverSelection(); s.front = pages[0].number; s.insideFront = pages[1].number
                        s.insideBack = pages[pages.count-2].number; s.back = pages.last?.number; model.bookSettings.selection = s
                    }
                }
            }
        }
    }
    private func pagePicker(_ title: String,_ key: WritableKeyPath<CoverSelection,Int?>,allowBlank: Bool = false) -> some View {
        Picker(title,selection:Binding(get:{ model.bookSettings.selection[keyPath:key] ?? -1 },set:{ value in
            model.bookSettings.selection[keyPath:key] = value<0 ? nil : value
            model.showBookSection(.cover)
        })) {
            let auto = model.project.resolvedCoverSelection[keyPath:key]
            Text(model.project.coverMode == .excluded ? "Seçiniz" : "Otomatik (\(auto.map { $0 == 0 ? "Boş" : model.coverPageLabel($0) } ?? "—"))").tag(-1)
            if allowBlank { Text("Boş").tag(0) }
            ForEach(model.bookCoverDomain,id:\.number) { page in Text(model.coverPageLabel(page.number)).tag(page.number) }
        }
    }
    private var spineControls: some View {
        VStack(alignment:.leading,spacing:7) {
            Text("Amerikan cilt: sırt ve kapak açılımı").font(.headline)
            measure("Kapak payı (mm) — varsayılan 0",book.coverAllowance)
            measure("Yapıştırıcı payı (mm) — varsayılan 0",book.adhesiveAllowance)
            Text("Sırt = (iç sayfa / 2) × iç kâğıt kalınlığı + kapak payı + yapıştırıcı payı").font(.caption)
            if let info,let spine = info.spine,let thickness = info.interiorPaper.millimetres {
                Text("(\(info.interiorPageCount) / 2) × \(TRFormat.dimension(thickness,detail:true)) + \(TRFormat.dimension(model.bookSettings.coverAllowance,detail:true)) + \(TRFormat.dimension(model.bookSettings.adhesiveAllowance,detail:true)) ≈ \(TRFormat.dimension(spine,detail:true)) mm").font(.caption).textSelection(.enabled)
            } else { Text("Kalınlık girilmeden sırt hesaplanamaz; çıktı engellenir.").font(.caption).foregroundStyle(DesignSystem.warning) }
            Text("İç sayfa sayısı, forma için eklenen boşları içerir. Kapak kalınlığı otomatik pay olarak eklenmez; kapak payını siz girin.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
            measure("Sol kulak (mm)",book.leftFlap)
            measure("Sağ kulak (mm)",book.rightFlap)
            Text("Panellerde kulak ve sırt boştur. Baskılı kulak / sırt için hazır açılım PDF’si kullanın.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }
    }
    private var creepControls: some View {
        VStack(alignment:.leading,spacing:7) {
            Toggle("Kat kalınlığı kaydırması",isOn:book.creepEnabled).inspectorSetting(model,"Kat kalınlığı kaydırması",SettingGuidance.detail("Kat kalınlığı kaydırması"))
            if model.bookSettings.creepEnabled && (model.bookSettings.interiorPaper.millimetres == nil || model.bookSettings.coverPaper.millimetres == nil) { Text("En çok kaydırma: hesaplanamadı").font(.caption).foregroundStyle(DesignSystem.warning) }
            else { Text("En çok kaydırma: \(TRFormat.dimension(info?.maximumCreep ?? 0)) mm").font(.caption) }
            Text("Basit doğrusal yaklaşım: iç yaprak i için kapak kalınlığı + i × iç kâğıt kalınlığı. Kapak kaydırılmaz; iç baskı kat yerine doğru kayar. Fiziksel katlama / kesim testiyle doğrulayın.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }
    }
    private func measure(_ title: String,_ binding: Binding<Double>) -> some View {
        HStack { Text(title).frame(maxWidth:.infinity,alignment:.leading); DimensionInput(title,value:binding,unit:title.contains("µm") ? "µm" : title.contains("Gramaj") ? "g/m²" : title.contains("katsayı") ? "" : "mm") }.inspectorSetting(model,title,SettingGuidance.detail(title))
    }
}

private struct PaperCaliperEditor: View {
    @ObservedObject var model:Workspace
    let title: String
    @Binding var paper: PaperCaliper
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).font(.headline)
            Picker("Kalınlık girişi",selection:$paper.input) {
                Text("Mikron (µm)").tag(PaperCaliper.Input.microns)
                Text("Gramaj × katsayı").tag(PaperCaliper.Input.grammage)
            }.pickerStyle(.segmented).inspectorSetting(model,"Kalınlık girişi",SettingGuidance.detail("Kalınlık girişi"))
            if paper.input == .microns { optional("Kalınlık (µm)",$paper.microns) }
            else {
                optional("Gramaj (g/m²)",$paper.grammage)
                optional("Cilt katsayısı (cm³/g)",$paper.bulk)
                Text("Gramaj × katsayı = µm; varsayılan katsayı yoktur.").font(.caption).foregroundStyle(DesignSystem.muted).lineLimit(1)
            }
            Text(TRFormat.presentation(paper.description)).font(.caption).foregroundStyle(paper.millimetres == nil ? DesignSystem.warning : DesignSystem.muted)
        }
    }
    private func optional(_ title: String,_ binding: Binding<Double?>) -> some View {
        HStack { Text(title).frame(maxWidth:.infinity,alignment:.leading); OptionalDimensionInput(title:title,value:binding,unit:title.contains("µm") ? "µm" : title.contains("Gramaj") ? "g/m²" : "") }.inspectorSetting(model,title,SettingGuidance.detail(title))
    }
}
