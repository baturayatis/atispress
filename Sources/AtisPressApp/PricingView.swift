import SwiftUI
import ImpositionCore
import PDFEngine
import UniformTypeIdentifiers

func money(_ value: Decimal?) -> String {
    guard let value else { return "girilmedi" }
    let f = NumberFormatter(); f.locale = Locale(identifier:"tr_TR"); f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
    return (f.string(from:value as NSDecimalNumber) ?? "girilmedi") + " ₺"
}
struct PriceNumber: View {
    var title: String
    @Binding var value: Decimal?
    @State private var input = ""
    private func parsed(_ text: String) -> Decimal? {
        guard text.range(of:"^[0-9]+([.,][0-9]*)?$",options:.regularExpression) != nil else { return nil }
        return Decimal(string:text.replacingOccurrences(of:",",with:"."),locale:Locale(identifier:"en_US_POSIX"))
    }
    private func display(_ v: Decimal?) -> String { v.map { NSDecimalNumber(decimal:$0).stringValue.replacingOccurrences(of:".",with:",") } ?? "" }
    var body: some View {
        HStack {
            Text(title).frame(minWidth:130,alignment:.leading)
            TextField(title,text:$input,prompt:Text("girilmedi"))
                .onAppear { input = display(value) }
                .onChange(of:input) { _,text in value = parsed(text) }
                .onChange(of:value) { _,v in if parsed(input) != v { input = display(v) } }
        }
    }
}
struct PriceEntryEditor: View {
    @Binding var entry: PriceEntry
    var body: some View {
        TextField("Ad",text:$entry.name)
        if entry.kind == .paper {
            TextField("Gramaj (g/m²)",value:$entry.grammage,format:.number,prompt:Text("girilmedi"))
            HStack { TextField("En (mm)",value:$entry.size.width,format:.number); TextField("Boy (mm)",value:$entry.size.height,format:.number) }
            Toggle("1000 tabaka fiyatı",isOn:$entry.perThousand)
            Toggle("KDV dahil",isOn:$entry.includesVAT)
        }
        PriceNumber(title:entry.kind == .digital ? "Ön / tabaka (₺)" : entry.kind == .offset ? "1000 tabaka baskı (₺)" : "Birim fiyat (₺)",value:$entry.price)
        if entry.kind == .digital { PriceNumber(title:"Arka / tabaka (₺)",value:$entry.backPrice) }
        if entry.kind == .offset {
            PriceNumber(title:"Kalıp başına (₺)",value:$entry.platePrice)
            PriceNumber(title:"Hazırlık / ayar (₺ / kalıp takımı)",value:$entry.setupPrice)
            TextField("Renk sayısı",value:$entry.colors,format:.number,prompt:Text("girilmedi"))
        }
        if entry.kind == .finishing { Picker("Birim",selection:$entry.unit) { ForEach(PriceUnit.allCases,id:\.self) { Text($0.rawValue).tag($0) } } }
    }
}
struct PricingView: View {
    @ObservedObject var store: PricingStore
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("Fiyatlar").font(.largeTitle.bold())
                Text("Bütün fiyatları siz girin. Boş alanlar girilmedi olarak kalır. Sıfır, açıkça girildiğinde geçerlidir.").foregroundStyle(.secondary)
                HStack { PriceNumber(title:"Kâr marjı (%)",value:$store.library.margin); PriceNumber(title:"KDV (%)",value:$store.library.vat) }
                ForEach(PriceKind.allCases,id:\.self) { kind in
                    GroupBox(kind.rawValue) {
                        VStack(alignment:.leading) {
                            ForEach($store.library.entries) { $entry in
                                if entry.kind == kind {
                                    VStack(alignment:.leading) {
                                        PriceEntryEditor(entry:$entry)
                                        Button("Sil",role:.destructive) { store.library.entries.removeAll { $0.id == entry.id } }
                                    }.padding(8)
                                    Divider()
                                }
                            }
                            Button("\(kind.rawValue) ekle") { store.library.entries.append(PriceEntry(kind:kind)) }
                            if kind == .finishing {
                                Menu("İşçilik ekle") { ForEach(["Kesim","Katlama","Tutkal cilt","Spiral","Tel cilt","Seri numara","Ambalaj"],id:\.self) { name in Button(name) { store.library.entries.append(PriceEntry(kind:.finishing,name:name)) } } }
                            }
                        }
                    }
                }
                HStack {
                    Button("Tablo dışa aktar…") { exportTable() }
                    Button("Tablo içe aktar…") { importTable() }
                }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                Text("Kâğıt: seçilen KDV oranıyla netleştirilir. Baskı ve işçilik fiyatları KDV hariçtir. İçe aktarma kitaplığı değiştirir; önce dışa aktararak yedekleyebilirsiniz.").font(.caption)
            }.textFieldStyle(.roundedBorder).padding(24)
        }.frame(minWidth:640,minHeight:600)
        .onChange(of:store.library) { _,_ in store.save() }
    }
    private func importTable() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        if p.runModal() == .OK,let url = p.url { do { try store.importFile(url) } catch { store.error = error.localizedDescription } }
    }
    private func exportTable() {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = "AtisPress-fiyatlar.json"
        if p.runModal() == .OK,let url = p.url { do { try store.exportFile(url) } catch { store.error = error.localizedDescription } }
    }
}
struct CostingView: View {
    @ObservedObject var model: Workspace
    @ObservedObject var store: PricingStore
    @State private var comparison: [SheetComparison] = []
    private var settings: Binding<JobCostSettings> { Binding(get:{ model.project.costing ?? JobCostSettings() },set:{ model.project.costing = $0 }) }
    private var result: CostResult { CostCalculator.calculate(project:model.project,plan:model.plan,library:store.library) }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("İş maliyeti").font(.largeTitle.bold())
                Text("Bu proje bir teklif işidir. Karışık işte ortak tabaka yalnız bir kez hesaplanır; adet bazlı işçilik bütün işlerin toplam adedine uygulanır.").font(.caption)
                selection("Kâğıt",kind:.paper,value:settings.paper)
                selection("Baskı",kind:nil,value:settings.printing)
                GroupBox("Ek işlemler") {
                    VStack(alignment:.leading) {
                        ForEach(store.library.entries.filter { $0.kind == .finishing }) { entry in
                            Toggle(entry.name,isOn:Binding(get:{ settings.wrappedValue.finishing.contains { $0.id == entry.id } },set:{ enabled in
                                var s = settings.wrappedValue
                                if enabled { s.finishing.append(PriceSelection(entry.id)) } else { s.finishing.removeAll { $0.id == entry.id } }
                                settings.wrappedValue = s
                            }))
                        }
                        ForEach(settings.wrappedValue.finishing.indices,id:\.self) { index in
                            overrideEditor(settings.finishing[index])
                        }
                    }
                }
                HStack {
                    PriceNumber(title:"Bu işe özel kâr (%)",value:settings.margin)
                    PriceNumber(title:"Bu işe özel KDV (%)",value:settings.vat)
                }
                Text("Boş bırakılan kâr/KDV kitaplıktan alınır. Kitaplık: kâr \(store.library.margin.map { "\($0)%" } ?? "girilmedi"), KDV \(store.library.vat.map { "\($0)%" } ?? "girilmedi")").font(.caption)
                if model.project.isBooklet || model.project.isLeafBinding { TextField("Yayın adedi",value:settings.copies,format:.number,prompt:Text("girilmedi")) }
                TextField("Ek fire tabakası (plandaki fireye ek)",value:settings.extraWasteSheets,format:.number)
                Text("Plan + fire: \(result.sheets) tabaka · Satış adedi: \(result.quantity)")
                if model.planning { Text("Plan hesaplanıyor…").foregroundStyle(.orange) }
                breakdown(result)
                Button("Tabaka karşılaştır") { comparison = EconomicSheets.compare(project:model.project,library:store.library) }.disabled(model.planning)
                ForEach(comparison) { row in
                    HStack {
                        VStack(alignment:.leading) {
                            Text(row.title + (row.cheapest ? " · En ekonomik" : "" )).bold()
                            Text(row.paperPriced ? "\(row.result.sheets) tabaka · Kâğıt \(money(row.result.lines.first?.amount)) · Toplam \(money(row.result.sale))" : "fiyat yok")
                            if row.paperPriced && row.result.sale == nil { Text(row.result.missing.joined(separator:"; ")).font(.caption) }
                        }
                        Spacer()
                        Button("Uygula") { model.project = row.project; model.sheetPreset = row.title; comparison = [] }.disabled(row.result.sale == nil)
                    }.padding(8).background(row.cheapest ? Color.green.opacity(0.12) : Color.gray.opacity(0.05))
                }
                quoteEditor
            }.padding(24).textFieldStyle(.roundedBorder)
        }.frame(minWidth:760,minHeight:650)
        .onChange(of:model.project) { old,new in
            comparison = []
            if old.costing?.printing?.id != new.costing?.printing?.id,let p = new.costing?.printing?.resolved(in:store.library) { model.setProduction(p.kind == .offset ? .offset : .digital) }
        }
        .onChange(of:store.library) { _,_ in comparison = [] }
    }
    private func selection(_ title: String,kind: PriceKind?,value: Binding<PriceSelection?>) -> some View {
        GroupBox(title) {
            VStack(alignment:.leading) {
                Picker(title,selection:Binding<UUID?>(get:{ value.wrappedValue?.id },set:{ value.wrappedValue = $0.map(PriceSelection.init) })) {
                    Text("girilmedi").tag(nil as UUID?)
                    ForEach(store.library.entries.filter { kind == nil ? ($0.kind == .digital || $0.kind == .offset) : $0.kind == kind }) { Text($0.name + " · " + $0.kind.rawValue).tag(Optional($0.id)) }
                }
                if value.wrappedValue != nil {
                    overrideEditor(Binding(get:{ value.wrappedValue! },set:{ value.wrappedValue = $0 }))
                }
            }
        }
    }
    private func overrideEditor(_ selection: Binding<PriceSelection>) -> some View {
        VStack(alignment:.leading) {
            Toggle("bu işe özel",isOn:Binding(get:{ selection.wrappedValue.override != nil },set:{ enabled in selection.wrappedValue.override = enabled ? selection.wrappedValue.resolved(in:store.library) : nil }))
            if selection.wrappedValue.override != nil {
                PriceEntryEditor(entry:Binding(get:{ selection.wrappedValue.override! },set:{ selection.wrappedValue.override = $0 }))
            }
        }
    }
    private func breakdown(_ r: CostResult) -> some View {
        GroupBox("Kalem / miktar / birim fiyat / tutar") {
            VStack(alignment:.leading,spacing:8) {
                ForEach(Array(r.lines.enumerated()),id:\.offset) { _,line in
                    HStack { Text(line.name); Spacer(); Text("\(NSDecimalNumber(decimal:line.quantity).stringValue) × \(money(line.unitPrice)) = \(money(line.amount))").monospacedDigit() }
                }
                ForEach(r.missing,id:\.self) { Text($0).foregroundStyle(.red) }
                Divider()
                Text("Toplam maliyet: \(money(r.cost)) · Kâr: \(money(r.profit))")
                Text("KDV: \(money(r.tax)) · Satış fiyatı: \(money(r.sale))").bold()
                Text("Adet başı fiyat: \(money(r.perCopy))")
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var quoteEditor: some View {
        GroupBox("Teklif PDF’i") {
            VStack(alignment:.leading) {
                TextField("Firma adı (isteğe bağlı)",text:settings.quote.company)
                HStack {
                    Button("Logo seç…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.png,.jpeg,.pdf]
                        if p.runModal() == .OK,let url = p.url { do { settings.quote.logo.wrappedValue = try Data(contentsOf:url) } catch { model.error = error.localizedDescription } }
                    }
                    if settings.quote.logo.wrappedValue != nil { Button("Logoyu kaldır") { settings.quote.logo.wrappedValue = nil } }
                }
                TextField("İş adı",text:settings.quote.jobName)
                TextField("Geçerlilik süresi",text:settings.quote.validity)
                TextField("Not",text:settings.quote.note,axis:.vertical).lineLimit(3...6)
                Toggle("Ayrıntılı maliyet dökümünü ekle",isOn:settings.quote.showCosts)
                Button("Teklif PDF’i dışa aktar…") { exportQuote() }.disabled(result.sale == nil || model.planning || settings.wrappedValue.quote.validity.trimmingCharacters(in:.whitespaces).isEmpty)
                if settings.wrappedValue.quote.validity.isEmpty { Text("Geçerlilik süresi girilmedi").foregroundStyle(.secondary) }
            }
        }
    }
    private func exportQuote() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Teklif.pdf"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        guard !(model.source?.protectedURLs ?? []).contains(where:{ $0.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() }),model.projectURL?.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath(),store.url.standardizedFileURL != url.standardizedFileURL else { model.error = "Teklif kaynak veya proje dosyasının üzerine yazılamaz."; return }
        do { try QuotePDFExporter.export(project:model.project,result:result,library:store.library,to:url) } catch { model.error = error.localizedDescription }
    }
}
