import SwiftUI
import ImpositionCore

struct BookInspectorView: View {
    @ObservedObject var model: Workspace
    @State private var calculator = false
    @State private var pages = false
    @State private var more = false
    private var book: Binding<BookSettings> { $model.bookSettings }
    private var info: BookSheetInfo? { model.plan.sheets.compactMap(\.bookInfo).first }
    private var prepared: Bool { model.coverModeForEditing == .separate && model.bookSettings.coverArtwork == .spread }

    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            if model.project.binding == .saddleStitch {
                Toggle("Kapak farklı kâğıda basılacak (ayrı tabaka)",isOn:$model.separateSaddleCover)
                    .inspectorTarget("coverMode").disabled(model.bookSettings.coverSourceID != nil)
            }
            measure("Sırt payı (mm)",ContextBindings(model:model).spine,range:0...1000)
                .inspectorTarget("coverMode")
            if model.project.binding != .saddleStitch {
                if model.spineWidth > 0 && !prepared { SpineContentEditor(model:model) }
                Button("Kalınlıktan hesapla…") { calculator = true }
                    .popover(isPresented:$calculator) {
                        SpineCalculatorView(book:model.bookSettings,
                            pageCount:info?.interiorPageCount ?? model.project.pages.count) { value in
                            model.spineWidth = value
                            calculator = false
                        }
                    }
            }
            if model.coverModeForEditing != .included || model.bookSettings.automaticCover != true && model.project.book != nil,
               let size = info?.spreadSize {
                Text("Açılım: \(TRFormat.dimension(size.width,detail:true)) × \(TRFormat.dimension(size.height,detail:true)) mm")
                    .monospacedDigit().textSelection(.enabled)
            }
            if let id = model.bookSettings.coverSourceID,
               let record = model.pageSourceRecords.first(where:{ $0.id == id }) {
                Text(record.reference.fileName).lineLimit(1)
                HStack {
                    Button("Değiştir…",action:model.chooseCoverPDF)
                    Button("Kaldır",action:model.removeCoverPDF)
                }
            } else {
                Button("PDF ekle…",action:model.chooseCoverPDF)
                    .disabled(model.source == nil || model.project.sourcePreparation?.hasPreparedProducts == true)
            }
            DisclosureGroup("Daha fazla",isExpanded:$more) {
                VStack(alignment:.leading,spacing:8) {
                    Button("Kapak sayfalarını değiştir…") { pages = true }
                        .disabled(model.coverModeForEditing == .included && model.bookSettings.automaticCover == true)
                        .popover(isPresented:$pages) {
                            VStack(alignment:.leading,spacing:8) {
                                if prepared {
                                    pagePicker("Dış açılım",\.front)
                                    pagePicker("İç açılım",\.insideFront,allowBlank:true)
                                } else {
                                    pagePicker("Ön kapak",\.front)
                                    pagePicker("İç ön",\.insideFront,allowBlank:true)
                                    pagePicker("İç arka",\.insideBack,allowBlank:true)
                                    pagePicker("Arka kapak",\.back)
                                }
                            }.padding(16).frame(width:330)
                        }
                    if model.coverModeForEditing == .separate {
                        Picker("PDF biçimi",selection:book.coverArtwork) {
                            Text("Tek yüzler").tag(BookSettings.CoverArtwork.panels)
                            Text("Hazır açılım").tag(BookSettings.CoverArtwork.spread)
                        }
                    }
                    if model.project.binding != .saddleStitch {
                        measure("Sol kulak (mm)",book.leftFlap)
                        measure("Sağ kulak (mm)",book.rightFlap)
                    } else {
                        SaddleCreepControls(model:model)
                    }
                }.padding(.top,6)
            }
        }.textFieldStyle(.roundedBorder)
    }

    private func pagePicker(_ title: String,_ key: WritableKeyPath<CoverSelection,Int?>,allowBlank: Bool = false) -> some View {
        Picker(title,selection:Binding(get:{ model.bookSettings.selection[keyPath:key] ?? -1 },set:{ value in
            var book = model.bookSettings
            if model.project.book == nil { book.automaticCover = true }
            if book.automaticCover != true && model.coverModeForEditing == .excluded {
                book.selection[keyPath:key] = value < 0 ? automaticSelection[keyPath:key] : value
            } else { book.selection[keyPath:key] = value < 0 ? nil : value }
            model.bookSettings = book
        })) {
            let automatic = automaticSelection[keyPath:key]
            Text(automatic.map { $0 == 0 ? "Otomatik (Boş)" : "Otomatik (\(model.coverPageLabel($0)))" } ?? "Otomatik").tag(-1)
            if allowBlank { Text("Boş").tag(0) }
            ForEach(model.project.book == nil ? model.project.pages : model.bookCoverDomain,id:\.number) { page in
                Text(model.coverPageLabel(page.number)).tag(page.number)
            }
        }
    }

    private var automaticSelection: CoverSelection {
        var project = model.project
        var book = model.bookSettings
        book.selection = CoverSelection()
        if model.coverModeForEditing == .excluded { book.automaticCover = true }
        project.book = book
        project.coverMode = model.coverModeForEditing
        return project.resolvedCoverSelection
    }

    private func measure(_ title: String,_ value: Binding<Double>,range: ClosedRange<Double> = 0...500) -> some View {
        HStack { Text(title); Spacer(); DimensionInput(title,value:value,range:range) }
    }
}

struct SaddleCreepControls: View {
    @ObservedObject var model: Workspace
    private var book: Binding<BookSettings> { $model.bookSettings }

    var body: some View {
        Toggle("Kat kalınlığı kaydırması",isOn:Binding(get:{ model.bookSettings.creepEnabled },set:{ enabled in
            var settings = model.bookSettings
            if model.project.book == nil { settings.automaticCover = true }
            settings.creepEnabled = enabled
            model.bookSettings = settings
        }))
        if model.bookSettings.creepEnabled {
            PaperCaliperEditor(model:model,title:"İç kâğıt",paper:book.interiorPaper)
            PaperCaliperEditor(model:model,title:"Kapak kâğıdı",paper:book.coverPaper)
        }
    }
}

struct SpineCalculatorView: View {
    @State private var microns: Double?
    @State private var cover: Double
    @State private var glue: Double
    let pageCount: Int
    let apply: (Double) -> Void

    init(book: BookSettings,pageCount: Int,apply: @escaping (Double) -> Void) {
        _microns = State(initialValue:book.interiorPaper.millimetres.map { $0*1000 })
        _cover = State(initialValue:book.coverAllowance)
        _glue = State(initialValue:book.adhesiveAllowance)
        self.pageCount = pageCount; self.apply = apply
    }

    var body: some View {
        let value = SpineCalculation(pageCount:pageCount,microns:microns,coverAllowance:cover,glueAllowance:glue).result
        VStack(alignment:.leading,spacing:10) {
            Text("İç sayfa sayısı: \(pageCount)")
            HStack { Text("Kâğıt kalınlığı"); Spacer(); OptionalDimensionInput(title:"Kâğıt kalınlığı",value:$microns,unit:"µm") }
            HStack { Text("Kapak payı"); Spacer(); DimensionInput("Kapak payı",value:$cover,range:0...500) }
            HStack { Text("Yapıştırıcı payı"); Spacer(); DimensionInput("Yapıştırıcı payı",value:$glue,range:0...500) }
            Text("Sırt = (iç sayfa / 2) × (µm / 1.000) + kapak payı + yapıştırıcı payı")
            if let value { Text("Sonuç: \(TRFormat.dimension(value,detail:true)) mm") }
            else if pageCount == 0 { Text("Önce iç sayfaları ekleyin.").foregroundStyle(DesignSystem.warning) }
            else { Text("Kalınlığı 0,01–10.000 µm, payları 0–500 mm girin. Sonuç en fazla 1.000 mm olabilir.").foregroundStyle(DesignSystem.warning) }
            Button("Uygula") { if let value { apply(value) } }.disabled(value == nil)
        }.padding(16).frame(width:390)
    }
}

struct PaperCaliperEditor: View {
    @ObservedObject var model:Workspace
    let title: String
    @Binding var paper: PaperCaliper
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).font(.headline)
            Picker("Kalınlık girişi",selection:$paper.input) {
                Text("Mikron (µm)").tag(PaperCaliper.Input.microns)
                Text("Gramaj × katsayı").tag(PaperCaliper.Input.grammage)
            }.pickerStyle(.segmented).inspectorTarget(title == "İç kâğıt" ? "paperCaliper" : nil).inspectorSetting(model,"Kalınlık girişi",SettingGuidance.detail("Kalınlık girişi"))
            if paper.input == .microns { optional("Kalınlık (µm)",$paper.microns) }
            else {
                optional("Gramaj (g/m²)",$paper.grammage)
                optional("Cilt katsayısı (cm³/g)",$paper.bulk)
                Text("Gramaj × katsayı = µm; varsayılan katsayı yoktur.").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
            }
            Text(TRFormat.presentation(paper.description)).font(.system(size:12)).foregroundStyle(paper.millimetres == nil ? DesignSystem.warning : DesignSystem.muted)
        }
    }
    private func optional(_ title: String,_ binding: Binding<Double?>) -> some View {
        HStack { Text(title).frame(maxWidth:.infinity,alignment:.leading); OptionalDimensionInput(title:title,value:binding,unit:title.contains("µm") ? "µm" : title.contains("Gramaj") ? "g/m²" : "") }.inspectorSetting(model,title,SettingGuidance.detail(title))
    }
}
