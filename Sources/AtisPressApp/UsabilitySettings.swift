import SwiftUI
import ImpositionCore

enum InspectorMode: String, CaseIterable { case simple = "Basit", advanced = "Gelişmiş" }
enum ProductKind: String, CaseIterable {
    case card = "Kartvizit", brochure = "Broşür", form = "Form", book = "Kitap", spiral = "Spiral"
    static func detect(_ project: Project) -> ProductKind {
        if project.isLeafBinding { return .spiral }
        if project.binding == .saddleStitch { return .brochure }
        if project.isBooklet { return .book }
        guard let size = project.pages.first?.trimSize else { return .card }
        if RescaleSettings.targets.prefix(2).contains(where: { abs($0.1.width-size.width)<0.1 && abs($0.1.height-size.height)<0.1 }) { return .card }
        return .form
    }
    var binding: BindingMethod {
        switch self { case .card,.form: return .stepAndRepeat; case .brochure: return .saddleStitch; case .book: return .perfectBound; case .spiral: return .spiral }
    }
}
enum InspectorSection: String, CaseIterable, Identifiable {
    case product = "Ürün", sheet = "Tabaka", edges = "Kenarlar ve Maşa", marks = "Taşma ve İşaretler", serial = "Seri Numara", binding = "Kitap/Cilt", price = "Fiyat"
    var id: String { rawValue }
    var fields: Set<AutoLayoutField> {
        switch self {
        case .product: return [.allowRotation,.columns,.rows,.gutter]
        case .sheet: return [.sheetSize,.orientation,.alignment]
        case .edges: return [.marginLeft,.marginRight,.marginTop,.marginBottom,.gripperEdge,.gripperWidth,.gutter]
        case .marks: return Set(AutoLayoutField.allCases).subtracting(InspectorSection.product.fields.union(InspectorSection.sheet.fields).union(InspectorSection.edges.fields))
        case .serial,.binding,.price: return []
        }
    }
    var keywords: String {
        switch self {
        case .product: return "ürün tipi kartvizit broşür form kitap spiral adet üretim dijital ofset ölçeklendir hedef ebat mod sığdır doldur esnet tekrarlı dizilim satır sütun sayfa düzeni hazır ayar gang karışık"
        case .sheet: return "tabaka boyut genişlik yükseklik yön hizalama otomatik sabit verimli"
        case .edges: return "kenarlar maşa sol sağ üst alt kenar payı ara boşluk"
        case .marks: return "taşma kesim uzunluğu uzaklığı güvenli alan tolerans renk üret yöntem cmyk rgb önizleme katmanlar ön kontrol boyut yama skala konumu renk skalası diz işaretleri katlama sayfa numaraları tabaka sınırı"
        case .serial: return "seri numara başlangıç artış bitiş basamak önek sonek yazı konum döndürme aralık dağıtımı yığın kopya blok qr barkod code 128 fire"
        case .binding: return "kitap cilt yöntem forma çevirme tel dikiş tutkallı dikişli kapak sırt creep kalınlık gramaj katsayı kulak yapıştırıcı boş sayfalar spiral wire delik çapı aralığı kenardan uzaklık"
        case .price: return "fiyat maliyet teklif kdv kâr kağıt kâğıt"
        }
    }
}
@MainActor
final class UsabilitySettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var mode: InspectorMode { didSet { defaults.set(mode.rawValue,forKey:"atispress.ui.mode"); if mode == .simple { search = "" } } }
    @Published var search = ""
    @Published var searchFocusRequest = 0
    @Published var revealedSection: InspectorSection?
    @Published private var collapsed: Set<String> { didSet { defaults.set(Array(collapsed),forKey:"atispress.ui.collapsed") } }
    init(defaults:UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey:"atispress.ui.mode").flatMap(InspectorMode.init(rawValue:)) ?? .simple
        collapsed = Set(defaults.stringArray(forKey:"atispress.ui.collapsed") ?? [InspectorSection.serial.rawValue,InspectorSection.binding.rawValue,InspectorSection.price.rawValue])
    }
    func isExpanded(_ section:InspectorSection) -> Bool { !search.isEmpty || !collapsed.contains(section.rawValue) }
    func setExpanded(_ section:InspectorSection,_ open:Bool) { if open { collapsed.remove(section.rawValue) } else { collapsed.insert(section.rawValue) } }
    func matches(_ text:String,section:InspectorSection? = nil) -> Bool {
        let locale = Locale(identifier:"tr_TR")
        func folded(_ value:String) -> String { value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:locale).lowercased(with:locale) }
        let words = folded(search).split(whereSeparator: { $0.isWhitespace })
        func includes(_ value:String) -> Bool { let haystack = folded(value); return words.allSatisfy { haystack.contains($0) } }
        return includes(text) || section.map { includes($0.rawValue) } == true
    }
    func shows(_ section:InspectorSection) -> Bool {
        (mode == .advanced || !search.isEmpty || ![.edges,.binding,.price].contains(section)) && matches(section.rawValue+" "+section.keywords)
    }
    func focusSearch() { mode = .advanced; searchFocusRequest += 1 }
    func reveal(_ section:InspectorSection) { mode = .advanced; search = ""; setExpanded(section,true); revealedSection = section }
    func productOverride(for id:UUID) -> ProductKind? { defaults.string(forKey:"atispress.ui.product."+id.uuidString).flatMap(ProductKind.init(rawValue:)) }
    func setProduct(_ product:ProductKind?,for id:UUID) { defaults.set(product?.rawValue,forKey:"atispress.ui.product."+id.uuidString); objectWillChange.send() }
}

struct SettingHelp: View {
    let title: String
    let detail: String
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName:"questionmark.circle").foregroundStyle(.secondary) }
            .buttonStyle(.borderless).accessibilityLabel(title+" yardımı")
            .popover(isPresented:$open) {
                VStack(alignment:.leading,spacing:8) { Text(title).font(.headline); Text(detail).fixedSize(horizontal:false,vertical:true) }.padding(14).frame(width:290)
            }.help(detail)
    }
}
enum SettingGuidance {
    static func title(_ field:AutoLayoutField) -> String {
        switch field {
        case .sheetSize: return "Tabaka boyutu"
        case .orientation: return "Yön"
        case .alignment: return "Hizalama"
        case .allowRotation: return "90° döndürme"
        case .marginLeft: return "Sol kenar payı"
        case .marginRight: return "Sağ kenar payı"
        case .marginTop: return "Üst kenar payı"
        case .marginBottom: return "Alt kenar payı"
        case .gripperEdge: return "Maşa kenarı"
        case .gripperWidth: return "Maşa payı"
        case .gutter: return "Ara boşluk dizilim"
        case .cropLength: return "Kesim uzunluğu"
        case .cropOffset: return "Kesim uzaklığı"
        case .bleed: return "Taşma"
        case .safeArea: return "Güvenli alan"
        case .generatedEnabled: return "Taşma üret"
        case .generatedMethod: return "Taşma yöntemi"
        case .generatedTolerance: return "Taşma toleransı"
        case .generatedColor: return "Taşma rengi CMYK RGB"
        case .columns: return "Sütun"
        case .rows: return "Satır"
        case .exportCrop: return "Kesim işaretleri"
        case .exportFold: return "Katlama işaretleri"
        case .exportBleed: return "Taşma çizgisi"
        case .exportSafeArea: return "Güvenli alan çizgisi"
        case .exportPageNumbers: return "Sayfa numaraları"
        case .exportSheetInfo: return "Tabaka bilgi şeridi"
        case .exportFullCut: return "Tam kesim çizgisi"
        case .exportLineWidth: return "Çizgi kalınlığı (pt)"
        case .exportColor: return "Çizgi rengi"
        case .exportColorBar: return "Renk skalası"
        case .exportTargets: return "Diz işaretleri"
        case .exportTargetSize: return "Diz boyutu (mm)"
        case .exportPatchSize: return "Yama boyutu (mm)"
        case .exportBarSide: return "Skala konumu"
        }
    }
    static func detail(_ field:AutoLayoutField) -> String {
        switch field {
        case .gripperWidth,.gripperEdge: return "Makinenin kâğıdı tuttuğu kenarı ve ayrılacak payı belirtir. Değer: makinenizin ölçülmüş mm payı veya Otomatik. Örnek: alt maşa, kullanılabilir alanı alt kenarda azaltır."
        case .gutter: return "Komşu ürünlerin aralığını belirler. Seçenekler: Bitişik, Aralıklı veya Özel; kitap katları 0 mm kalır. Örnek: Aralıklı seçiminde ara boşluk taşmanın iki katıdır."
        case .generatedEnabled,.generatedMethod,.generatedTolerance,.generatedColor: return "Eksik taşmayı yalnız kesim dışında tamamlar. Seçenekler: Otomatik, Yansıt veya Renk; mevcut otomatik tolerans %2’dir. Örnek: tek renk kenar vektör dolgu ile uzatılır."
        case .sheetSize,.orientation,.alignment: return "Baskı kâğıdını, yönünü veya kullanılabilir alandaki konumunu seçer. Tipik seçim: Otomatik ve Ortala. Örnek: Otomatik tabaka, ürüne sığan mevcut kâğıtlardan seçilir."
        case .columns,.rows,.allowRotation: return "Düzenli ızgaradaki kopya sayısını ve 90° dönüş iznini belirler. Tipik seçim: Otomatik. Örnek: dönüş daha çok kopya sığdırıyorsa otomatik yerleşim bunu kullanabilir."
        case .marginLeft,.marginRight,.marginTop,.marginBottom: return "Kâğıdın bu kenarındaki kullanılmayan alanı mm olarak ayırır. Tipik seçim: Otomatik; özel değer makinenize göre ölçülür. Örnek: sol pay artınca kullanılabilir genişlik azalır."
        case .bleed,.cropLength,.cropOffset,.safeArea: return "Kesim çevresindeki taşma, işaret veya güvenli alan mesafesidir; birimi mm’dir. Tipik seçim: Otomatik. Örnek: kesim uzunluğu 0 ise kesim işareti çizilmez."
        case .exportLineWidth: return "Çıktı işaretinin çizgi kalınlığını punto olarak belirler. Değer: mevcut pt ölçüsü. Örnek: artırınca kesim işareti kalınlaşır; artwork değişmez."
        case .exportColor: return "Çıktı işaretlerinin rengini seçer. Seçenekler: Siyah veya tüm kalıplarda kayıt rengi. Örnek: kayıt rengi CMYK’nın dört kanalına basılır."
        case .exportTargetSize,.exportPatchSize: return "Diz işareti veya renk yamasının mm boyutudur. Değer: baskı makinenizin kontrol alanına göre ölçülür. Örnek: boyut artarsa kenarda daha fazla boş alan gerekir."
        case .exportBarSide: return "Renk skalasının basılacağı kâğıt kenarını seçer. Seçenekler: Maşa tarafı veya karşı taraf. Örnek: karşı taraf seçimi skalayı maşa kenarının tersine taşır."
        default: return "Yalnız mevcut PDF çıktı işaretini değiştirir. Seçenekler: Açık/Kapalı; renk ve kalınlık mevcut değerlerdir. Örnek: güvenli alan açıkken kılavuz çizgisi PDF’ye basılır."
        }
    }
}
private struct SettingRowModifier: ViewModifier {
    @ObservedObject var model: Workspace
    let title:String
    let detail:String
    let keywords:String
    @Environment(\.inspectorSection) private var section
    func body(content:Content) -> some View {
        if model.ui.matches(title+" "+keywords,section:section) { HStack(alignment:.top,spacing:5) { content; SettingHelp(title:title,detail:detail) } }
    }
}
extension View {
    func inspectorSetting(_ model:Workspace,_ title:String,_ detail:String,keywords:String = "") -> some View { modifier(SettingRowModifier(model:model,title:title,detail:detail,keywords:keywords)) }
}

enum ExportPreset: String, CaseIterable {
    case press = "Matbaaya gönder", digital = "Dijital baskı", proof = "Kontrol çıktısı"
    func applying(to original:ExportMarks) -> ExportMarks {
        var marks = original
        marks.crop = true; marks.fold = self != .digital
        marks.bleed = self == .proof; marks.safeArea = self == .proof; marks.pageNumbers = self == .proof
        marks.sheetInfo = self != .digital; marks.fullCut = false
        marks.colorBar = self == .press; marks.registrationTargets = self == .press
        return marks
    }
}

private struct InspectorSectionKey: EnvironmentKey { static let defaultValue:InspectorSection? = nil }
private struct InspectorSearchEnabledKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var inspectorSection:InspectorSection? {
        get { self[InspectorSectionKey.self] }
        set { self[InspectorSectionKey.self] = newValue }
    }
    var inspectorSearchEnabled:Bool {
        get { self[InspectorSearchEnabledKey.self] }
        set { self[InspectorSearchEnabledKey.self] = newValue }
    }
}
private struct SettingHintModifier: ViewModifier {
    let title:String
    let detail:String
    func body(content:Content) -> some View { HStack(alignment:.center,spacing:5) { content; SettingHelp(title:title,detail:detail) } }
}
extension View {
    func settingHint(_ title:String,_ detail:String) -> some View { modifier(SettingHintModifier(title:title,detail:detail)) }
}
extension SettingGuidance {
    static func detail(_ title:String) -> String {
        let key = title.lowercased(with:Locale(identifier:"tr_TR"))
        if key == "tür" { return "Seri alanının metin, QR kod veya Code 128 barkod olarak çizilmesini seçer. Örnek: QR seçildiğinde içerik şablonu ve kod boyutu açılır." }
        if key == "pdf biçimi" { return "Kapak PDF’sinin tek tek yüzler mi, hazır açılım mı içerdiğini belirtir. Seçenekler: Tek tek kapak yüzleri / Hazır açılım. Örnek: hazır açılımda dış açılım sayfası tek panel olarak kullanılır." }
        if key == "yöntem" { return "Mevcut yerleşim/ciltleme yöntemini seçer. Seçenekler: Tekrarlı, Karışık iş, Tel dikiş, Tutkallı/Dikişli cilt, Spiral/Wire-O. Örnek: Tel dikiş katlanıp iç içe geçen yapraklar üretir." }
        if key.contains("kalınlık") || key.contains("gramaj") || key.contains("katsayı") { return "Kâğıdın ölçülmüş kalınlığını belirtir. Seçenekler: mikron veya gramaj × cilt katsayısı; katsayı uydurulmaz. Örnek: gramaj × katsayı, mikron kalınlığını verir." }
        if key.contains("kapak") || key.contains("açılım") { return "Kapağın iç sayfalara dahil, ayrı veya ayrı PDF olarak nasıl işleneceğini belirler. Tipik seçim: mevcut PDF’nizin gerçek kapak biçimi. Örnek: Ayrı PDF seçimi kapak kaynağını ayrıca bağlar." }
        if key.contains("cilt") || key.contains("delik") || key.contains("creep") || key.contains("kulak") || key.contains("yapıştırıcı") { return "Cilt veya delik için makinede ölçülen değeri kullanır; birim alan etiketindedir. Otomatik bir makine payı yoktur. Örnek: cilt kenarı Sol seçilirse pay sol kenarda ayrılır." }
        if key.contains("fire") { return "İstenen ürün adedine üretim fazlası ekler. Seçenekler: yüzde veya sabit adet; numaralı/numarasız. Örnek: yüzde fire hesabı yukarı yuvarlanır." }
        if key.contains("aralık") || key.contains("arka yüz numara") || key == "mod" { return "Numaraların kopya, blok veya işlere dağılımını seçer. Seçenekler: Kopya/Blok/İş, Sıralı/Yığın veya Ön ile aynı/Ardışık. Örnek: Ardışık seçiminde ön ve arka yüz 1/2 olur." }
        if key.contains("basamak") || key.contains("başlangıç") || key.contains("artış") || key.contains("bitiş") { return "Serinin sayısal aralığını veya baştaki sıfırlarını belirler. Otomatik basamak seçimi tüm aralığa göre hesaplanır. Örnek: basamak sayısı arttığında başa sıfır eklenir." }
        if key.contains("sessiz") || key.contains("hata düzelt") || key.contains("şablon") || key.contains("okunabilir") { return "QR/Code 128 içeriğini ve okunabilirliğini ayarlar. Değerler: mevcut hata düzeltme seçenekleri, modül veya mm. Örnek: {no} yer tutucusu numara ile değiştirilir; yer tutucu yoksa kod sabittir." }
        if key.contains("dönüş") || key.contains("x (") || key.contains("y (") { return "Alanı kesimin sol alt köşesine göre yerleştirir; konum mm, dönüş derecedir. Tipik değer: tasarımın ölçülmüş konumu. Örnek: X artınca alan sağa kayar." }
        if key.contains("yazı") || key.contains("boyut (pt)") { return "Seri metninin mevcut yazı tipini veya punto boyutunu seçer. Tipik seçim: listede bulunan yazı tipi. Örnek: yazı tipi bulunamazsa sistem yedeği kullanılır." }
        if key.contains("çevirme") { return "Kalıbın ön ve arka yüzde nasıl kullanılacağını seçer. Seçenekler: Ayrı kalıp, Yan çevirme, Takla. Örnek: yan çevirmede aynı kalıp iki yarımda kullanılır." }
        if key.contains("forma") { return "Katlanacak forma sayfa sayısını belirler. Seçenekler: Otomatik veya mevcut 4/8/16/32 sayfa. Örnek: sabit forma son grupta tamamlama boşları gerektirebilir." }
        if key.contains("sayfa düzeni") { return "Seçili sayfaların ön/arka işlere eşlenmesini belirler. Seçenekler: Otomatik, Tek yüz, Çift yüz. Örnek: Çift yüz, seçili sıradaki 1–2 sayfayı eşler." }
        if key.contains("boş") { return "Tamamlama boşlarının konumunu veya boş arka yüzlerin çıktısını seçer. Seçenekler: mevcut Sona/Başa/Elle veya Açık/Kapalı. Örnek: Boş arka yüzü eklemek çift yüz hizalamasını korur." }
        if key.contains("hedef") || key.contains("ölçek") { return "Mevcut hedef ebat ve ölçekleme ayarını seçer. Seçenekler: Sığdır, Doldur veya Esnet. Örnek: Doldur oranı korur ve hedef dışını kırpar." }
        if key.contains("katman") || key.contains("çizgi") || key.contains("işaret") || key.contains("tabaka sınırı") || key.contains("sayfa numara") { return "Bu kılavuzun görünürlüğünü veya mevcut çıktı işaretini seçer. Seçenekler: Açık/Kapalı. Örnek: önizleme katmanını kapatmak PDF çıktı işaretini kapatmaz." }
        return "Bu alanın mevcut üretim seçimini değiştirir. Değer: listelenen seçenek veya etiket biriminde ölçülmüş değer. Örnek: yapılan değişiklik aynı planın önizlemesine yansır; elle girilen değer korunur."
    }
}

private struct InspectorFilterModifier: ViewModifier {
    @ObservedObject var model:Workspace
    let keywords:String
    @Environment(\.inspectorSection) private var section
    func body(content:Content) -> some View { if model.ui.matches(keywords,section:section) { content } }
}
extension View {
    func inspectorFilter(_ model:Workspace,_ keywords:String) -> some View { modifier(InspectorFilterModifier(model:model,keywords:keywords)) }
}
