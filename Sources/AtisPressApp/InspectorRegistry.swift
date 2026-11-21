import Foundation
import ImpositionCore

enum InspectorPanel: String, CaseIterable, Identifiable, Codable {
    case job, sheet, montage, dimensions, cut, separation, serial, press, color, price, output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .job: return "İş"
        case .sheet: return "Tabaka"
        case .montage: return "Montaj"
        case .dimensions: return "Ölçüler"
        case .cut: return "Kesim"
        case .separation: return "İş Ayır"
        case .serial: return "Seri No"
        case .press: return "Baskı"
        case .color: return "Renk"
        case .price: return "Fiyat"
        case .output: return "Çıktı"
        }
    }

    var help: String {
        switch self {
        case .dimensions: return "Kenar, maşa, taşma ve hedef ebat ayarları."
        case .sheet: return "Baskı tabakası ve önizleme kılavuzları."
        case .cut: return "Kesim işaretleri, iç kesimler ve işaret ölçüleri."
        case .press: return "Üretim türü, diz işaretleri ve tabaka bilgi şeridi."
        case .color: return "Ton, renk skalası ve PDF renk bilgileri."
        case .output: return "PDF çıktısı ve ön kontrol."
        case .separation: return "PDF bölgelerini, sayfa bölmeyi ve kaynak kılavuzlarını düzenleyin."
        case .montage: return "Yüz eşlemesini, yerleşimi ve cilt ayrıntılarını ayarlayın."
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .job: return "doc.text"
        case .sheet: return "rectangle.portrait"
        case .montage: return "square.grid.2x2"
        case .dimensions: return "ruler"
        case .cut: return "crop"
        case .separation: return "rectangle.split.2x2"
        case .serial: return "number.square"
        case .press: return "printer"
        case .color: return "paintpalette"
        case .price: return "turkishlirasign.circle"
        case .output: return "square.and.arrow.up"
        }
    }

    static func restoring(_ key: String) -> Self? {
        switch key {
        case "edges", "bleed", "scaling": return .dimensions
        case "marks": return .cut
        case "binding": return .montage
        default: return Self(rawValue: key)
        }
    }

    static func neighbor(of panel: Self, step: Int, visible: [Self]) -> Self? {
        guard let index = visible.firstIndex(of: panel) else { return nil }
        return visible[min(visible.count - 1, max(0, index + step))]
    }

    static func legacy(_ section: InspectorSection) -> Self {
        switch section {
        case .product: return .job
        case .sheet: return .sheet
        case .edges, .marks: return .dimensions
        case .serial: return .serial
        case .binding: return .montage
        case .price: return .price
        }
    }

    // Keep the existing number shortcuts when groups move to another panel.
    static let shortcuts: [InspectorShortcut] = [
        .init(1, .job, .jobBasics), .init(2, .sheet, .paper),
        .init(3, .dimensions, .edges), .init(4, .dimensions, .bleed),
        .init(5, .cut, .printedMarks), .init(6, .serial, .serialFields),
        .init(7, .dimensions, .scale), .init(8, .montage, .binding),
        .init(9, .price, .cost),
        .init(10, .press, .production, optionKey: "b"),
        .init(11, .color, .tone, optionKey: "r")
    ]
}

struct InspectorShortcut: Identifiable {
    let id: Int
    let panel: InspectorPanel
    let group: InspectorGroup
    let optionKey: Character?
    var key: Character { optionKey ?? Character(String(id)) }
    var displayShortcut: String { (optionKey == nil ? "⌘" : "⌥⌘") + String(key).uppercased() }

    init(_ id: Int, _ panel: InspectorPanel, _ group: InspectorGroup, optionKey: Character? = nil) {
        self.id = id
        self.panel = panel
        self.group = group
        self.optionKey = optionKey
    }

    func isAvailable(for project: Project) -> Bool {
        panel.groups(for: project).contains(destination(for: project))
    }

    func destination(for project: Project) -> InspectorGroup {
        group == .binding ? .bindingEntry(for: project) : group
    }
}

enum InspectorGroup: String, Identifiable, Hashable {
    case jobBasics, method, waste, presets, paper, products, placement, jobFaces
    case binding, cover, bookPaper, spine, blanks
    case edges, bleed, generatedBleed, scale, printedMarks, internalCuts, cutMeasures, separation
    case serialFields, serialContent, serialRange, serialAppearance, serialPosition
    case production, tone, colorControls, colorSizes, colorInfo, registration, sheetInfo, preview
    case cost, labor, result, quote, priceLibrary, output, preflight

    var id: Self { self }

    static func bindingEntry(for project: Project) -> Self {
        project.binding == .saddleStitch ? .cover : .binding
    }

    var title: String {
        switch self {
        case .jobBasics: return "Ürün ve adet"
        case .method: return "Yerleşim yöntemi"
        case .waste: return "Fire ayrıntıları"
        case .presets: return "Hazır ayarlar"
        case .paper: return "Baskı tabakası"
        case .products: return "Ürünler ve yüzler"
        case .placement: return "Yerleşim ve çevirme"
        case .jobFaces: return "İşe özel yüz eşlemesi"
        case .binding: return "Cilt"
        case .cover: return "Kapak ve Sırt"
        case .bookPaper: return "Cilt kâğıdı"
        case .spine: return "Sırt ve creep"
        case .blanks: return "Sayfa düzeni"
        case .edges: return "Kenar payları ve maşa"
        case .bleed: return "Taşma payı"
        case .generatedBleed: return "Üretilmiş taşma"
        case .scale: return "Hedef ebat ve ölçek"
        case .printedMarks: return "Baskı işaretleri"
        case .internalCuts: return "İç kesim"
        case .cutMeasures: return "İşaret ölçüleri"
        case .separation: return "Bölme ve kaynak kılavuzları"
        case .serialFields: return "Alanlar"
        case .serialContent: return "İçerik"
        case .serialRange: return "Aralık"
        case .serialAppearance: return "Görünüm"
        case .serialPosition: return "Konum"
        case .production: return "Üretim"
        case .tone: return "Ton"
        case .colorControls: return "Renk skalası"
        case .colorSizes: return "Skala ölçüleri"
        case .colorInfo: return "Renk bilgileri"
        case .registration: return "Diz işaretleri"
        case .sheetInfo: return "Tabaka bilgisi"
        case .preview: return "Önizleme katmanları"
        case .cost: return "Maliyet"
        case .labor: return "İşçilik"
        case .result: return "Sonuç"
        case .quote: return "Teklif"
        case .priceLibrary: return "Fiyat kitaplığı"
        case .output: return "PDF çıktısı"
        case .preflight: return "Ön kontrol"
        }
    }
}

/// The inspector and navigation consume the same inventory. The frozen test
/// inventory independently verifies that legacy editor bindings remain reachable.
enum InspectorRegistry {
    private static let legacySettingsByEditor:[String:Set<String>] = [
        "InspectorView": ["autoLayout", "binding", "blockAlignment", "book", "exportMarks.crop", "gang", "isBooklet", "isLeafBinding", "keyPath.bleed", "keyPath.crop", "keyPath.cropMarkLength", "keyPath.cropMarkOffset", "keyPath.offset", "keyPath.safeArea", "keyPath.safeAreaInset", "model.editableGeneratedBleed.color", "model.editableGeneratedBleed.color.components", "model.editableGeneratedBleed.color.components.count", "model.editableGeneratedBleed.enabled", "model.editableGeneratedBleed.method", "model.editableGeneratedBleed.tolerance", "model.overlays.bleed", "model.overlays.colorBar", "model.overlays.crop", "model.overlays.fold", "model.overlays.pageNumbers", "model.overlays.pressGuides", "model.overlays.punch", "model.overlays.registrationTargets", "model.overlays.safeArea", "model.overlays.sheetBoundary", "model.pageLayoutMode", "model.repeatArrangement", "model.sheetPreset", "pages.count", "pages.isEmpty", "settings.bleed", "settings.cropMarkLength", "settings.signatureSize", "settings.turnMethod", "sheet.gripperEdge", "sheet.gripperWidth", "sheet.gutter", "sheet.margins.bottom", "sheet.margins.left", "sheet.margins.right", "sheet.margins.top", "sheet.orientation", "sheet.size", "sheet.size.height", "sheet.size.width", "stepAndRepeat.allowRotation", "stepAndRepeat.columns", "stepAndRepeat.quantity", "stepAndRepeat.rows"],
        "BookInspectorView": ["adhesiveAllowance", "binding", "book", "bulk", "coverAllowance", "coverArtwork", "coverMode", "coverPaper", "creepEnabled", "description", "grammage", "input", "interiorPaper", "keyPath.back", "keyPath.bookInfo", "keyPath.front", "keyPath.insideBack", "keyPath.insideFront", "leftFlap", "microns", "millimetres", "model.bookSettings", "model.bookSettings.adhesiveAllowance", "model.bookSettings.coverAllowance", "model.bookSettings.coverArtwork", "model.bookSettings.coverPaper.millimetres", "model.bookSettings.coverSourceID", "model.bookSettings.creepEnabled", "model.bookSettings.interiorPaper.millimetres", "model.bookSettings.selection", "resolvedCoverSelection", "rightFlap"],
        "LeafInspectorView": ["allowance", "book", "coverMode", "diameter", "keyPath.back", "keyPath.front", "keyPath.leafInfo", "keyPath.offset", "leafSettings", "leafSettings.allowance", "keyPath.behavior", "keyPath.edge", "keyPath.holes", "model.bookSettings.selection", "model.overlays.pressGuides", "model.overlays.punch", "model.overlays.safeArea", "offset", "pages", "pitch", "stepAndRepeat.allowRotation"],
        "BlankPlacementView": ["blankPagePolicy", "keyPath.offset", "model.blankSettings.mode", "model.blankSettings.positions", "model.blankSettings.positions.contains", "model.blankSettings.positions.count"],
        "SerialInspectorView": ["backNumbering", "binding", "codeSettings.humanFontSize", "codeSettings.humanReadable", "color", "color.components", "color.components.count", "content", "digitNote", "digits", "digitsAreManual", "distribution", "font", "id", "jobIndex", "keyPath.offset", "kind", "mode", "model.editableSerialFields", "model.editableSerialFields.count", "model.editableSerialFields.filter", "model.editableSerialFields.first", "model.editableSerialFields.firstIndex", "model.editableSerialFields.removeAll", "position.x", "position.y", "prefix", "rangeDescription", "rotation", "showsEndNumber", "sides", "size", "start", "step", "stepAndRepeat.quantity", "suffix", "usesSerialNumber", "value"],
        "SerialCodeControlsView": ["codeSettings.correction", "codeSettings.height", "codeSettings.humanReadable", "codeSettings.quietZone", "codeSettings.template", "codeSettings.width", "content", "kind"],
        "RescaleInspectorView": ["binding", "book", "gang", "hasInvalidScaling", "isBooklet", "isValid", "migrateScaling", "mode", "pages.filter", "pages.first", "repeatJobs.enumerated", "scaling", "scalingSettings"],
        "InspectorControls": ["settings"],
        "ScaleWindowView": ["target", "target.height", "target.width"],
        "PreviewLayersView": ["model.overlays"],
        "ColorControlSizeView": ["exportMarks.barSide", "exportMarks.patchSize", "exportMarks.targetSize"],
        "ExportMarksView": ["exportMarks", "exportMarks.bleed", "exportMarks.color", "exportMarks.colorBar", "exportMarks.crop", "exportMarks.fold", "exportMarks.fullCut", "exportMarks.lineWidth", "exportMarks.pageNumbers", "exportMarks.registrationTargets", "exportMarks.safeArea", "exportMarks.sheetInfo", "includeBlankBacks", "keyPath.date", "keyPath.production", "keyPath.sheetNumber", "keyPath.sheetSize", "keyPath.showJobName", "keyPath.side", "model.infoJobName"],
        "PricingView": ["backPrice", "colors", "copies", "costing", "extraWasteSheets", "finishing", "finishing.contains", "finishing.indices", "grammage", "id", "includesVAT", "isBooklet", "isLeafBinding", "keyPath.offset", "kind", "margin", "model.sheetPreset", "name", "override", "paper", "perThousand", "platePrice", "price", "printing", "quote.company", "quote.jobName", "quote.logo.wrappedValue", "quote.note", "quote.showCosts", "quote.validity", "quote.validity.isEmpty", "quote.validity.trimmingCharacters", "resolved", "setupPrice", "size.height", "size.width", "unit", "vat", "wrappedValue"],
        "FireControlsView": ["fixed", "mode", "numberCopies", "percent", "stepAndRepeat.waste"],
        "GangInspectorView": ["gang", "keyPath.allowRotation", "keyPath.bleed", "keyPath.element.id", "keyPath.element.number", "keyPath.job.id", "keyPath.name", "keyPath.saved.id", "keyPath.tint", "model.editableSerialFields.contains", "quantities"],
        "PresetInspectorView": ["autoLayout"],
    ]
    static let settingsByEditor=legacySettingsByEditor.merging([
        "InternalCutMarksView": ["internalCutJobs"],
        "TeamInspectorView": ["team", "manualLayouts", "allowRotation", "duplex"],
        "SourcePageTools":Set(["columns","rows","verticalCuts","horizontalCuts","cells.product","cells.side","cellBleed","explicitTrim.width","explicitTrim.height","learnedTrimCenters","hiddenGuideGroups","ignoreSplitSuggestion"])
    ],uniquingKeysWith:{$0.union($1)})
    struct Setting:Identifiable {
        let editor:String
        let path:String
        let panel:InspectorPanel
        var id:String {editor+"."+path}
    }
    static let settings:[Setting] = settingsByEditor.keys.sorted().flatMap {editor in
        settingsByEditor[editor]!.sorted().map {Setting(editor:editor,path:$0,panel:owner(editor:editor,path:$0))}
    }
    static func owner(editor:String,path:String) -> InspectorPanel {
        if path.hasPrefix("model.overlays.") {
            if editor == "LeafInspectorView" { return .montage }
            return .sheet
        }
        switch editor {
        case "BookInspectorView","LeafInspectorView","BlankPlacementView":return .montage
        case "SerialInspectorView","SerialCodeControlsView":return .serial
        case "RescaleInspectorView","ScaleWindowView":return .dimensions
        case "SourcePageTools":return .separation
        case "TeamInspectorView","GangInspectorView":return .montage
        case "ColorControlSizeView":return path == "exportMarks.targetSize" ? .press : .color
        case "PreviewLayersView":return .sheet
        case "InternalCutMarksView":return .cut
        case "PricingView":return .price
        case "ExportMarksView":
            if path == "includeBlankBacks" { return .output }
            if path == "exportMarks.colorBar" { return .color }
            if ["exportMarks.registrationTargets", "exportMarks.sheetInfo",
                "keyPath.date", "keyPath.production", "keyPath.sheetNumber", "keyPath.sheetSize",
                "keyPath.showJobName", "keyPath.side", "model.infoJobName"].contains(path) { return .press }
            return .cut
        case "FireControlsView","PresetInspectorView":return .job
        default:
            if path=="settings.signatureSize" || path=="book" {return .montage}
            if ["settings.turnMethod", "model.pageLayoutMode", "model.repeatArrangement", "stepAndRepeat.allowRotation", "stepAndRepeat.columns", "stepAndRepeat.rows"].contains(path) { return .montage }
            if path=="blockAlignment" || path.contains("margins") || path.contains("gripper") || path=="sheet.gutter" {return .dimensions}
            if path.contains("GeneratedBleed") || path.contains("bleed") {return .dimensions}
            if path.contains("overlays") || path.contains("exportMarks") || path.contains("crop") || path.contains("safeArea") {return .cut}
            if path.contains("sheet") || path.contains("gutter") || path.contains("columns") || path.contains("rows") || path.contains("allowRotation") || path.contains("repeatArrangement") {return .sheet}
            return .job
        }
    }
    static func owner(_ field:AutoLayoutField) -> InspectorPanel {
        switch field {
        case .generatedEnabled,.generatedMethod,.generatedColor,.generatedTolerance,.bleed:return .dimensions
        case .cropLength,.cropOffset,.safeArea:return .cut
        case .exportCrop,.exportFold,.exportFullCut,.exportLineWidth,.exportColor:return .cut
        case .exportColorBar,.exportPatchSize,.exportBarSide:return .color
        case .exportTargets,.exportTargetSize:return .press
        case .columns,.rows,.allowRotation:return .montage
        case .exportBleed,.exportSafeArea,.exportPageNumbers:return .cut
        case .exportSheetInfo:return .press
        case .marginLeft,.marginRight,.marginTop,.marginBottom,.gripperEdge,.gripperWidth,.gutter,.alignment:return .dimensions
        default:return .sheet
        }
    }
    static func fields(_ panel:InspectorPanel) -> [AutoLayoutField] {AutoLayoutField.allCases.filter{owner($0)==panel}}
}

extension InspectorPanel {
    func groups(for project: Project) -> [InspectorGroup] {
        switch self {
        case .job: return [.jobBasics, .method, .waste, .presets]
        case .sheet: return [.paper, .preview]
        case .montage:
            if project.isLeafBinding { return [.placement, .binding, .cover] }
            if project.isBooklet {
                let signature: [InspectorGroup] = project.binding == .saddleStitch ? [] : [.binding]
                return [.placement] + signature + [.cover, .blanks]
            }
            if project.binding == .stepAndRepeat { return [.products, .placement, .jobFaces] }
            return [.products, .placement]
        case .dimensions: return [.edges, .bleed, .scale, .generatedBleed]
        case .cut: return [.printedMarks, .internalCuts, .cutMeasures]
        case .separation: return [.separation]
        case .serial: return [.serialFields, .serialContent, .serialRange, .serialAppearance, .serialPosition]
        case .press: return [.production, .registration, .sheetInfo]
        case .color: return [.tone, .colorControls, .colorSizes, .colorInfo]
        case .price: return [.cost, .labor, .result, .quote, .priceLibrary]
        case .output: return [.output, .preflight]
        }
    }

    func initiallyExpanded(_ group: InspectorGroup, for project: Project) -> Bool {
        groups(for: project).first == group || group == .bleed || group == .cover
    }
}
