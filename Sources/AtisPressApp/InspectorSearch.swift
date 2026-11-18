import Foundation
import ImpositionCore

struct InspectorSearchEntry: Identifiable {
    let id: String
    let title: String
    let panel: InspectorPanel
    let group: InspectorGroup
    let isAvailable: @MainActor (Workspace) -> Bool
    private let label: String
    private let index: String

    init(_ id: String, _ title: String, _ panel: InspectorPanel, _ group: InspectorGroup,
         _ keywords: String = "", available: @escaping @MainActor (Workspace) -> Bool = { _ in true }) {
        self.id = id
        self.title = title
        self.panel = panel
        self.group = group
        isAvailable = available
        label = Self.normalize(title)
        index = Self.normalize([title, panel.title, group.title, keywords].joined(separator: " "))
    }

    @MainActor func canOpen(in model: Workspace) -> Bool {
        panel.groups(for: model.project).contains(group) && isAvailable(model)
    }

    static func matches(_ query: String) -> [Self] {
        let text = normalize(query)
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return [] }
        func rank(_ entry: Self) -> Int {
            if entry.label == text { return 0 }
            if entry.label.hasPrefix(text) { return 1 }
            if words.allSatisfy({ entry.label.contains($0) }) { return 2 }
            return 3
        }
        return entries.filter { entry in words.allSatisfy { entry.index.contains($0) } }
            .sorted {
                let first = rank($0), second = rank($1)
                if first != second { return first < second }
                let order = $0.title.compare($1.title, options: .caseInsensitive, locale: turkish)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    private static let turkish = Locale(identifier: "tr_TR")

    private static func normalize(_ value: String) -> String {
        value.lowercased(with: turkish)
            .folding(options: .diacriticInsensitive, locale: turkish)
            .replacingOccurrences(of: "ı", with: "i")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    @MainActor static func serialField(in model: Workspace) -> SerialField? {
        guard model.project.binding == .stepAndRepeat || (model.project.binding == .gang && model.selectedGangJob != nil) else { return nil }
        let job = model.currentSheet?.repeatLayout?.jobIndex ?? 0
        let fields = model.editableSerialFields.filter { $0.jobIndex == job }
        return fields.first(where: { $0.id == model.selectedSerialID }) ?? fields.first
    }

    static func sheetID(_ chip: String) -> String { "sheet." + normalize(chip) }

    static let entries: [Self] = [
        .init("product", "Ürün tipi", .job, .jobBasics, "kartvizit broşür kitap spiral"),
        .init("quantity", "Adet", .job, .jobBasics, "miktar tiraj kopya"),
        .init("wastePercent", "Fire yüzdesi", .job, .jobBasics, "yüzde ek üretim payı"),
        .init("countQuantity", "Adet hesapla", .job, .jobBasics, "her iş için miktar") { $0.project.binding == .stepAndRepeat },
        .init("method", "Yerleşim yöntemi", .job, .method, "yöntem cilt tekrarlı karışık gang tel dikiş"),
        .init("wasteMode", "Fire türü", .job, .waste, "sabit adet yüzde"),
        .init("wasteAmount", "Ek üretim payı", .job, .waste, "fire miktarı sabit adet yüzde"),
        .init("wasteCopies", "Fire kopyalar", .job, .waste, "numaralı numarasız") { $0.project.team == nil },
        .init("preset", "Hazır ayar", .job, .presets, "preset şablon"),
        .init("orientation", "Yön", .sheet, .paper, "yatay dikey portre manzara"),
        .init("sheetWidth", "Tabaka genişliği", .sheet, .paper, "özel en mm") { $0.sheetPreset == "Özel" },
        .init("sheetHeight", "Tabaka yüksekliği", .sheet, .paper, "özel boy mm") { $0.sheetPreset == "Özel" },
        .init("production", "Üretim", .press, .production, "ofset dijital baskı"),
        .init("sheetSelection", "Tabaka seçimi", .sheet, .paper, "sabit verimli otomatik kağıt"),
        .init("startTeam", "Takım olarak diz", .montage, .products, "çok sayfalı PDF set") { $0.canStartTeam },
        .init("pageLayout", "Sayfa düzeni", .montage, .products, "tek yüz çift yüz eşleme") {
            ($0.source?.pages.count ?? $0.project.pages.count) > 1 && $0.project.binding == .stepAndRepeat
        },
        .init("teamDuplex", "Takım baskısı", .montage, .products, "tek yüz çift yüz takım baskı") { $0.project.team != nil && $0.project.sourcePreparation?.separation == nil },
        .init("teamPlacement", "Takım yerleşimi", .montage, .products, "otomatik elle manuel blok") { $0.project.team != nil },
        .init("gangMode", "Karışık iş düzeni", .montage, .products, "gang otomatik elle manuel") { $0.project.binding == .gang && $0.project.team == nil },
        .init("turn", "Ön/arka çevirme", .montage, .placement, "ayrı kalıp yandan baştan duplex takla") { $0.showsTurnControl },
        .init("arrangement", "Dizilim", .montage, .placement, "bitişik aralıklı özel tekrarlı") { $0.project.binding == .stepAndRepeat },
        .init("rotate", "90° döndürmeye izin ver", .montage, .placement, "rotasyon dönüş") { $0.project.binding == .stepAndRepeat },
        .init("columns", "Sütun sayısını belirle", .montage, .placement, "kolon ızgara") { $0.project.binding == .stepAndRepeat },
        .init("rows", "Satır sayısını belirle", .montage, .placement, "ızgara sıra") { $0.project.binding == .stepAndRepeat },
        .init("teamRotation", "Takımda 90° döndürmeye izin ver", .montage, .products, "rotasyon dönüş") { $0.project.team != nil },
        .init("coverMode", "Kapak modu", .montage, .cover, "ayrı PDF dahil kapak") { $0.project.isLeafBinding || $0.project.book != nil },
        .init("bookSettings", "Kitap ayarlarını aç", .montage, .cover, "cilt kapak kâğıt") { $0.project.isBooklet && $0.project.book == nil },
        .init("paperCaliper", "İç kâğıt kalınlık girişi", .montage, .bookPaper, "mikron gramaj bulk") { $0.project.book != nil },
        .init("bindingEdge", "Cilt kenarı", .montage, .binding, "spiral Wire-O delik") { $0.project.isLeafBinding },
        .init("holes", "Delik işaretleri", .montage, .binding, "spiral çıktı delgeç") { $0.project.isLeafBinding },
        .init("blankPlacement", "Boş sayfalar nereye", .montage, .blanks, "sona başa manuel dolgu"),
        .init("signature", "Forma", .montage, .binding, "cilt sayfa sayısı katlama") { !$0.project.isLeafBinding },
        .init("leftMargin", "Sol kenar payı", .dimensions, .edges, "marj mm"),
        .init("rightMargin", "Sağ kenar payı", .dimensions, .edges, "marj mm"),
        .init("topMargin", "Üst kenar payı", .dimensions, .edges, "marj mm"),
        .init("bottomMargin", "Alt kenar payı", .dimensions, .edges, "marj mm"),
        .init("gripperEdge", "Maşa kenarı", .dimensions, .edges, "tutucu kıskaç"),
        .init("gripperWidth", "Maşa payı", .dimensions, .edges, "tutucu kıskaç genişlik mm"),
        .init("gutter", "Ara boşluk", .dimensions, .edges, "aralık gutter komşu") { !$0.project.isBooklet },
        .init("alignment", "Hizalama", .dimensions, .edges, "ortala maşaya yasla"),
        .init("bleed", "Taşma payı", .dimensions, .bleed, "bleed mm kesim dışı"),
        .init("generateBleed", "Eksik taşmayı üret", .dimensions, .bleed, "bleed tamamla"),
        .init("scale", "Ebadı değiştir", .dimensions, .scale, "ölçek hedef ebat sığdır doldur esnet") { !$0.scalingRows.isEmpty },
        .init("bleedMethod", "Üretilmiş taşma yöntemi", .dimensions, .generatedBleed, "yansıt otomatik renk dolgu") {
            ($0.selectedGangJob?.bleed ?? $0.project.settings.bleed) > 0 && $0.editableGeneratedBleed.enabled
        },
        .init("crop", "Kesim işaretleri", .cut, .printedMarks, "çıktı crop baskı"),
        .init("fold", "Katlama işaretleri", .cut, .printedMarks, "çıktı kırım forma") { $0.project.isBooklet },
        .init("printBleed", "Taşma çizgisi", .cut, .printedMarks, "çıktı bleed baskı"),
        .init("printSafe", "Güvenli alan", .cut, .printedMarks, "çıktı baskı"),
        .init("printNumbers", "Sayfa numaraları", .cut, .printedMarks, "çıktı yuva etiketleri"),
        .init("fullCut", "Tam kesim çizgisi", .cut, .printedMarks, "ürün üstü çıktı"),
        .init("lineColor", "Çizgi rengi", .cut, .printedMarks, "siyah kayıt tüm kalıplar"),
        .init("lineWidth", "Çizgi kalınlığı", .cut, .printedMarks, "pt punto"),
        .init("cropLength", "Kesim uzunluğu", .cut, .cutMeasures, "işaret ölçü mm"),
        .init("cropOffset", "Kesim uzaklığı", .cut, .cutMeasures, "mesafe ofset mm") { $0.project.settings.cropMarkLength > 0 },
        .init("safeInset", "Güvenli alan ölçüsü", .cut, .cutMeasures, "iç boşluk mm"),
        .init("horizontalCut", "Yatay kesim", .cut, .internalCuts, "iç kesim giyotin orta özel") { $0.project.hasPanelItems },
        .init("verticalCut", "Dikey kesim", .cut, .internalCuts, "iç kesim giyotin orta özel") { $0.project.hasPanelItems },
        .init("separate", "Akıllı İş Ayırma", .separation, .separation, "bölgeleri ve yüzleri düzenle artboard") { $0.canSeparateArtwork },
        .init("split", "Sayfayı böl", .separation, .separation, "birden fazla ürün kart ızgara") { $0.canSplitSource },
        .init("guides", "Kılavuz çizgileri", .separation, .separation, "gizle göster kaynak guide") {
            $0.canInspectSourceGuides && ($0.preparationInput?.guides.count ?? 0) > 0
        },
        .init("serialAdd", "Alan ekle", .serial, .serialFields, "seri no numara QR barkod") {
            ($0.project.binding == .stepAndRepeat || ($0.project.binding == .gang && $0.selectedGangJob != nil)) &&
                $0.editableSerialFields.count < 100
        },
        .init("serialKind", "Seri alanı türü", .serial, .serialContent, "metin QR kod barkod code 128") { serialField(in: $0) != nil },
        .init("serialDistribution", "Aralık dağıtımı", .serial, .serialRange, "kopya blok iş") { serialField(in: $0) != nil },
        .init("serialBack", "Arka yüz numarası", .serial, .serialRange, "ardışık ön ile aynı") { serialField(in: $0) != nil },
        .init("serialStart", "Başlangıç", .serial, .serialRange, "seri ilk numara") { serialField(in: $0)?.usesSerialNumber == true },
        .init("serialStep", "Artış", .serial, .serialRange, "seri adım sıra") { serialField(in: $0)?.usesSerialNumber == true },
        .init("serialFont", "Yazı tipi", .serial, .serialAppearance, "font metin") {
            guard let field = serialField(in: $0) else { return false }
            return field.kind == .text || field.codeSettings.humanReadable
        },
        .init("serialFaces", "Seri numara yüzleri", .serial, .serialPosition, "ön arka") { serialField(in: $0) != nil },
        .init("serialX", "Seri konumu X", .serial, .serialPosition, "yatay mm") { serialField(in: $0) != nil },
        .init("serialY", "Seri konumu Y", .serial, .serialPosition, "dikey mm") { serialField(in: $0) != nil },
        .init("colorBar", "Renk skalası", .color, .colorControls, "baskı şeridi kalıp CMYK çıktı"),
        .init("targets", "Diz işaretleri", .press, .registration, "baskı kayıt register registration hizalama çıktı"),
        .init("targetSize", "Diz boyutu", .press, .registration, "işaret ölçü mm") { $0.project.exportMarks.registrationTargets || $0.overlays.registrationTargets },
        .init("patchSize", "Renk yaması", .color, .colorSizes, "skala yama ölçü mm") { $0.project.exportMarks.colorBar || $0.overlays.colorBar },
        .init("barSide", "Skala konumu", .color, .colorSizes, "maşa kenar") { $0.project.exportMarks.colorBar || $0.overlays.colorBar },
        .init("sheetInfo", "Tabaka bilgi şeridi", .press, .sheetInfo, "iş adı tarih tabaka no ön arka"),
        .init("artworkTone", "Ton", .color, .tone, "açık koyu beyaz siyah ön arka"),
        .init("colorInfo", "Renk bilgileri", .color, .colorInfo, "PDF RGB CMYK spot mürekkep analiz ön kontrol"),
        .init("previewCrop", "Kesim çizgisi kılavuzu", .sheet, .preview, "önizleme katman"),
        .init("previewFold", "Katlama kılavuzu", .sheet, .preview, "önizleme kırım katman") { $0.project.isBooklet || $0.project.isLeafBinding },
        .init("previewPunch", "Delik kılavuzları", .sheet, .preview, "önizleme spiral katman") { $0.project.isLeafBinding },
        .init("previewBleed", "Taşma kılavuzu", .sheet, .preview, "önizleme bleed katman"),
        .init("previewSafe", "Güvenli alan kılavuzu", .sheet, .preview, "önizleme katman"),
        .init("previewNumbers", "Sayfa numaraları kılavuzu", .sheet, .preview, "önizleme katman"),
        .init("previewSheet", "Tabaka sınırı", .sheet, .preview, "önizleme katman"),
        .init("previewGripper", "Kenar payı / maşa kılavuzu", .sheet, .preview, "önizleme katman"),
        .init("previewColor", "Renk skalası kılavuzu", .sheet, .preview, "önizleme katman"),
        .init("previewTargets", "Diz kılavuzları", .sheet, .preview, "önizleme katman kayıt"),
        .init("paperCost", "Kâğıt fiyatı", .price, .cost, "maliyet fiyat kâğıt tabaka"),
        .init("printingCost", "Baskı fiyatı", .price, .cost, "maliyet fiyat ofset dijital"),
        .init("extraWaste", "Ek fire", .price, .cost, "maliyet tabaka ek üretim"),
        .init("compareSheets", "Tabaka karşılaştır", .price, .result, "ekonomik maliyet") { !$0.planning },
        .init("quoteCompany", "Teklif firma adı", .price, .quote, "müşteri şirket"),
        .init("quoteValidity", "Geçerlilik süresi", .price, .quote, "teklif tarih"),
        .init("quoteBreakdown", "Ayrıntılı maliyet dökümü", .price, .quote, "teklif hesap"),
        .init("priceImport", "Fiyat tablosu içe aktar", .price, .priceLibrary, "kitaplık csv fiyat"),
        .init("priceExport", "Fiyat tablosu dışa aktar", .price, .priceLibrary, "kitaplık csv fiyat"),
        .init("preparePDF", "PDF’i Hazırla", .output, .output, "dışa aktar çıktı export") { $0.canExportNow },
        .init("blankBacks", "Boş arka yüzleri çıktıya ekle", .output, .output, "PDF çift taraf baskı") {
            $0.plan.hasBlankBacks && $0.plan.hasBackContent
        }
    ] + WorkflowPresentation.sheetChips.map { chip in
        .init(sheetID(chip), "Tabaka " + chip, .sheet, .paper, "kağıt kâğıt boyut ebat")
    }

    static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
}
