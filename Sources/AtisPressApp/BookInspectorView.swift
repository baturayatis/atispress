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
                    if let info { Text(info.summary).font(.caption).textSelection(.enabled) }
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
            Picker("Kapak modu",selection:Binding(get:{ model.project.coverMode },set:{ value in
                if (value == .separate) != (model.project.coverMode == .separate) { model.bookSettings.selection = CoverSelection() }
                model.project.coverMode = value
            })) {
                Text("İç sayfalara dahil").tag(CoverMode.included)
                Text("Hariç — ayrı bas").tag(CoverMode.excluded)
                Text("Ayrı PDF").tag(CoverMode.separate)
            }.inspectorSetting(model,"Kapak modu",SettingGuidance.detail("Kapak modu"))
            if model.project.coverMode == .included {
                Text("İlk iki / son iki sayfa otomatik kapaktır. Seçilen kapak yüzleri iç bloktan ayrılır ve bağımsız basılır.").font(.caption).foregroundStyle(DesignSystem.muted)
            }
            if model.project.coverMode == .separate {
                Button("Kapak PDF yükle…",action:model.chooseCoverPDF).disabled(model.source == nil || model.loading)
                if let id = model.bookSettings.coverSourceID,let asset = model.gangAssets.first(where:{ $0.saved.id==id }) {
                    Text(asset.saved.reference.fileName).font(.caption)
                }
                Picker("PDF biçimi",selection:book.coverArtwork) {
                    Text("Tek tek kapak yüzleri").tag(BookSettings.CoverArtwork.panels)
                    Text("Hazır açılım (dış / iç)").tag(BookSettings.CoverArtwork.spread)
                }.inspectorSetting(model,"PDF biçimi",SettingGuidance.detail("PDF biçimi"))
            }
            if model.project.coverMode == .separate && model.bookSettings.coverArtwork == .spread {
                pagePicker("Dış açılım",\.front)
                pagePicker("İç açılım",\.insideFront,allowBlank:true)
                Text("Açılım PDF’si ölçeklenmez. Ölçü farkı tam sayılarla bildirilir; artwork hesaplanan açılıma kırpılır.").font(.caption).foregroundStyle(DesignSystem.muted)
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
                Text(String(format:"(%d / 2) × %.4f + %.3f + %.3f ≈ %.3f mm",info.interiorPageCount,thickness,model.bookSettings.coverAllowance,model.bookSettings.adhesiveAllowance,spine)).font(.caption).textSelection(.enabled)
            } else { Text("Kalınlık girilmeden sırt hesaplanamaz; çıktı engellenir.").font(.caption).foregroundStyle(DesignSystem.warning) }
            Text("İç sayfa sayısı, forma için eklenen boşları içerir. Kapak kalınlığı otomatik pay olarak eklenmez; kapak payını siz girin.").font(.caption).foregroundStyle(DesignSystem.muted)
            measure("Sol kulak (mm)",book.leftFlap)
            measure("Sağ kulak (mm)",book.rightFlap)
            Text("Panellerde kulak ve sırt boştur. Baskılı kulak / sırt için hazır açılım PDF’si kullanın.").font(.caption).foregroundStyle(DesignSystem.muted)
        }
    }
    private var creepControls: some View {
        VStack(alignment:.leading,spacing:7) {
            Toggle("Creep açık",isOn:book.creepEnabled).inspectorSetting(model,"Creep açık",SettingGuidance.detail("Creep açık"))
            if model.bookSettings.creepEnabled && (model.bookSettings.interiorPaper.millimetres == nil || model.bookSettings.coverPaper.millimetres == nil) { Text("En çok kaydırma: hesaplanamadı").font(.caption).foregroundStyle(DesignSystem.warning) }
            else { Text("En çok kaydırma: \(info?.maximumCreep ?? 0,specifier:"%.3f") mm").font(.caption) }
            Text("Basit doğrusal yaklaşım: iç yaprak i için kapak kalınlığı + i × iç kâğıt kalınlığı. Kapak kaydırılmaz; iç artwork kat yerine doğru kayar. Fiziksel katlama / kesim testiyle doğrulayın.").font(.caption).foregroundStyle(DesignSystem.muted)
        }
    }
    private func measure(_ title: String,_ binding: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value:binding,format:.number).frame(width:80) }.inspectorSetting(model,title,SettingGuidance.detail(title))
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
                Text("Gramaj × cilt katsayısı").tag(PaperCaliper.Input.grammage)
            }.inspectorSetting(model,"Kalınlık girişi",SettingGuidance.detail("Kalınlık girişi"))
            if paper.input == .microns { optional("Kalınlık (µm)",$paper.microns) }
            else {
                optional("Gramaj (g/m²)",$paper.grammage)
                optional("Cilt katsayısı (cm³/g)",$paper.bulk)
                Text("Gramaj × katsayı = µm; varsayılan katsayı yoktur.").font(.caption).foregroundStyle(DesignSystem.muted)
            }
            Text(paper.description).font(.caption).foregroundStyle(paper.millimetres == nil ? DesignSystem.warning : DesignSystem.muted)
        }
    }
    private func optional(_ title: String,_ binding: Binding<Double?>) -> some View {
        HStack { Text(title); Spacer(); TextField("Girilmedi",value:binding,format:.number).frame(width:85) }.inspectorSetting(model,title,SettingGuidance.detail(title))
    }
}
