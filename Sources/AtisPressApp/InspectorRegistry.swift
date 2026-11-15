import Foundation
import ImpositionCore

enum InspectorPanel:String,CaseIterable,Identifiable,Codable {
    case job, sheet, edges, bleed, marks, serial, scaling, binding, price, output
    var id:String {rawValue}
    var number:Int {Self.allCases.firstIndex(of:self)!+1}
    var title:String {
        switch self {
        case .job: return "İş"
        case .sheet: return "Tabaka"
        case .edges: return "Kenarlar"
        case .bleed: return "Taşma"
        case .marks: return "İşaretler"
        case .serial: return "Seri No"
        case .scaling: return "Ölçek ve Böl"
        case .binding: return "Cilt"
        case .price: return "Fiyat"
        case .output: return "Çıktı"
        }
    }
    var shortTitle:String {
        switch self {case .scaling:return "Ölçek/Böl";case .binding:return "Cilt/Kitap";default:return title}
    }
    var symbol:String {
        switch self {
        case .job:return "doc.text"
        case .sheet:return "rectangle.portrait"
        case .edges:return "arrow.up.left.and.arrow.down.right"
        case .bleed:return "drop"
        case .marks:return "crop"
        case .serial:return "number.square"
        case .scaling:return "rectangle.split.2x2"
        case .binding:return "book.closed"
        case .price:return "turkishlirasign.circle"
        case .output:return "square.and.arrow.up"
        }
    }
    static func visible(for project:Project) -> [Self] {
        allCases.filter {$0 != .binding || project.isBooklet || project.isLeafBinding}
    }
    static func neighbor(of panel:Self,step:Int,visible:[Self]) -> Self? {
        guard let index=visible.firstIndex(of:panel),!visible.isEmpty else {return nil}
        return visible[min(visible.count-1,max(0,index+step))]
    }
    static func legacy(_ section:InspectorSection) -> Self {
        switch section {
        case .product:return .job
        case .sheet:return .sheet
        case .edges:return .edges
        case .marks:return .bleed
        case .serial:return .serial
        case .binding:return .binding
        case .price:return .price
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
        if path.hasPrefix("model.overlays.") {return .marks}
        switch editor {
        case "BookInspectorView","LeafInspectorView","BlankPlacementView":return .binding
        case "SerialInspectorView","SerialCodeControlsView":return .serial
        case "RescaleInspectorView","ScaleWindowView","SourcePageTools":return .scaling
        case "PricingView":return .price
        case "ExportMarksView":return path=="includeBlankBacks" ? .output : .marks
        case "ColorControlSizeView","PreviewLayersView":return .marks
        case "FireControlsView","GangInspectorView","PresetInspectorView":return .job
        default:
            if path=="settings.signatureSize" || path=="book" {return .binding}
            if path=="settings.turnMethod" {return .sheet}
            if path=="blockAlignment" || path.contains("margins") || path.contains("gripper") || path=="sheet.gutter" {return .edges}
            if path.contains("GeneratedBleed") || path.contains("bleed") {return .bleed}
            if path.contains("overlays") || path.contains("exportMarks") || path.contains("crop") || path.contains("safeArea") {return .marks}
            if path.contains("sheet") || path.contains("gutter") || path.contains("columns") || path.contains("rows") || path.contains("allowRotation") || path.contains("repeatArrangement") {return .sheet}
            return .job
        }
    }
    static func owner(_ field:AutoLayoutField) -> InspectorPanel {
        switch field {
        case .generatedEnabled,.generatedMethod,.generatedColor,.generatedTolerance,.bleed:return .bleed
        case .cropLength,.cropOffset,.safeArea:return .marks
        case .exportCrop,.exportFold,.exportFullCut,.exportLineWidth,.exportColor,.exportColorBar,.exportTargets,.exportTargetSize,.exportPatchSize,.exportBarSide:return .marks
        case .exportBleed,.exportSafeArea,.exportPageNumbers:return .marks
        case .exportSheetInfo:return .marks
        case .marginLeft,.marginRight,.marginTop,.marginBottom,.gripperEdge,.gripperWidth,.gutter,.alignment:return .edges
        default:return .sheet
        }
    }
    static func fields(_ panel:InspectorPanel) -> [AutoLayoutField] {AutoLayoutField.allCases.filter{owner($0)==panel}}
}

// Sub-groups replace long stacks within the selected panel.
extension InspectorPanel {
    func groups(for project:Project) -> [String] {
        if self == .binding && project.isLeafBinding {return ["Cilt", "Kapak"]}
        return groups
    }
    var groups:[String] {
        switch self {
        case .job:return ["İş", "Yöntem", "Ürünler", "Fire", "Hazır ayar"]
        case .sheet:return ["Tabaka", "Yerleşim"]
        case .edges:return ["Kenarlar"]
        case .bleed:return ["Taşma", "Yöntem"]
        case .marks:return ["Baskı", "Ölçüler", "Renk", "Bilgi", "Katmanlar"]
        case .serial:return ["Alanlar", "İçerik", "Aralık", "Görünüm", "Konum"]
        case .scaling:return ["Ölçek/Böl"]
        case .binding:return ["Cilt", "Kapak", "Kâğıt", "Sırt ve creep", "Boş sayfalar"]
        case .price:return ["Maliyet", "İşçilik", "Sonuç", "Teklif", "Fiyat kitaplığı"]
        case .output:return ["Çıktı", "Ön kontrol"]
        }
    }
}
