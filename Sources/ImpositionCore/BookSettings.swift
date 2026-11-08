import Foundation

/// Explicit stock measurements. No physical stock value is inferred or supplied by default.
public struct PaperCaliper: Equatable, Codable, Sendable {
    public enum Input: String, Codable, Sendable { case microns, grammage }
    public var input: Input = .microns
    public var microns: Double?
    public var grammage: Double?
    /// Bulk / binding factor in cm³/g: gsm × factor yields micrometres.
    public var bulk: Double?
    public init() {}
    public var millimetres: Double? {
        let value: Double
        switch input {
        case .microns: guard let microns else { return nil }; value = microns/1000
        case .grammage: guard let grammage,let bulk else { return nil }; value = grammage*bulk/1000
        }
        return value.isFinite && value>0 && value<=10 ? value : nil
    }
    public var isValid: Bool {
        let values = input == .microns ? [microns] : [grammage,bulk]
        guard values.compactMap({ $0 }).allSatisfy({ $0.isFinite && $0>0 }) else { return false }
        return values.contains(where:{ $0 == nil }) || millimetres != nil
    }
    public var description: String {
        let inputText: String
        if input == .microns { inputText = (microns.map { String(format:"%.1f",$0) } ?? "—")+" µm" }
        else { inputText = (grammage.map { String(format:"%.1f",$0) } ?? "—")+" g/m² × "+(bulk.map { String(format:"%.3f",$0) } ?? "—")+" cm³/g" }
        guard let mm = millimetres else { return inputText+"; kalınlık hesaplanamadı" }
        return inputText+String(format:" ≈ %.4f mm",mm)
    }
}
public struct CoverSelection: Equatable, Codable, Sendable {
    /// nil chooses the automatic role in included/separate mode; zero is an explicitly blank inside.
    public var front: Int?
    public var insideFront: Int?
    public var insideBack: Int?
    public var back: Int?
    public init() {}
}
public struct BookSettings: Equatable, Codable, Sendable {
    public enum CoverArtwork: String, Codable, Sendable { case panels, spread }
    public var interiorPaper = PaperCaliper()
    public var coverPaper = PaperCaliper()
    public var coverAllowance: Double = 0
    public var adhesiveAllowance: Double = 0
    public var creepEnabled = false
    public var leftFlap: Double = 0
    public var rightFlap: Double = 0
    public var selection = CoverSelection()
    public var coverArtwork: CoverArtwork = .panels
    public var coverSourceID: UUID?
    public var coverPDFPages: [Int] = []
    /// Prior cover links remain in the catalog; none of their pages become interior artwork.
    public var auxiliaryPages: [Int] = []
    public init() {}
    public var isValid: Bool {
        interiorPaper.isValid && coverPaper.isValid &&
        [coverAllowance,adhesiveAllowance,leftFlap,rightFlap].allSatisfy { $0.isFinite && (0...500).contains($0) }
    }
}

public struct MeasuredSpineCalculator: SpineThicknessCalculating, Sendable {
    public var coverAllowance: Double
    public var adhesiveAllowance: Double
    public init(coverAllowance: Double = 0,adhesiveAllowance: Double = 0) {
        self.coverAllowance = coverAllowance; self.adhesiveAllowance = adhesiveAllowance
    }
    public func thickness(pageCount: Int,stockCaliper: Double) -> Double {
        Double(pageCount)/2*stockCaliper+coverAllowance+adhesiveAllowance
    }
}
/// Simple nested-leaf approximation, not a bindery calibration.
/// The independent outer cover stays at zero. Interior leaf i shifts c + i*t toward its fold.
public struct LinearCreepCalculator: CreepCalculating, Sendable {
    public var interiorThickness: Double
    public var coverThickness: Double
    public init(interiorThickness: Double,coverThickness: Double = 0) {
        self.interiorThickness = interiorThickness; self.coverThickness = coverThickness
    }
    public func displacement(sheetIndex: Int,sheetCount: Int) -> Double {
        displacement(sheetIndex:sheetIndex,sheetCount:sheetCount,stockCaliper:interiorThickness)
    }
    public func displacement(sheetIndex: Int,sheetCount: Int,stockCaliper: Double) -> Double {
        guard sheetCount>0,sheetIndex>=0,sheetIndex<sheetCount else { return 0 }
        return coverThickness+Double(sheetIndex)*stockCaliper
    }
}
public struct BookSheetInfo: Equatable, Sendable {
    public enum Section: Sendable { case interior, cover }
    public var pagination = ""
    public var pdfSides = 0
    public var section: Section
    public var interiorPageCount: Int
    public var spine: Double?
    public var spreadSize: Size
    public var interiorPaper: PaperCaliper
    public var coverPaper: PaperCaliper
    public var maximumCreep: Double
    public var creepEnabled = false
    public var bleed: Double = 0
    public var bleedClippedToSheet = false
    public var coverAllowance: Double = 0
    public var adhesiveAllowance: Double = 0
    public var leftFlap: Double = 0
    public var rightFlap: Double = 0
    public var label: String { section == .cover ? "Kapak" : "İç sayfalar" }
    public var summary: String {
        let spineText = spine.map { String(format:"%.3f mm",$0) } ?? "hesaplanamadı"
        let creepText = creepEnabled && (interiorPaper.millimetres == nil || coverPaper.millimetres == nil) ? "hesaplanamadı" : String(format:"%.3f mm",maximumCreep)
        let spreadText = spine == nil ? "hesaplanamadı" : String(format:"%.2f × %.2f mm",spreadSize.width,spreadSize.height)
        let bleedText: String
        if spine == nil { bleedText = " · Taşmalı açılım hesaplanamadı" }
        else if bleedClippedToSheet { bleedText = String(format:" · Taşma %.2f mm: tabaka sınırında kırpılır",bleed) }
        else { bleedText = String(format:" · Taşma dahil %.2f × %.2f mm",spreadSize.width+2*bleed,spreadSize.height+2*bleed) }
        return "\(pagination) · PDF yüzü: \(pdfSides) · \(label) · İç: \(interiorPageCount) sayfa · Sırt: \(spineText) · Açılım: "+spreadText+bleedText+" · İç kâğıt: \(interiorPaper.description) · Kapak: \(coverPaper.description) · En çok creep: "+creepText+String(format:" · Sırt payları: %.3f + %.3f mm · Kulaklar: %.2f / %.2f mm",coverAllowance,adhesiveAllowance,leftFlap,rightFlap)
    }
}

extension Project {
    public var isBooklet: Bool { binding == .saddleStitch || binding == .perfectBound || binding == .sewn }
    public var bookCoverPages: [SourcePage] {
        guard let book else { return [] }
        if coverMode == .separate { return book.coverPDFPages.compactMap { n in pages.first { $0.number == n } } }
        return pages.filter { !book.auxiliaryPages.contains($0.number) }
    }
    public var resolvedCoverSelection: CoverSelection {
        guard let book else { return CoverSelection() }
        let domain = bookCoverPages
        var selection = book.selection
        guard coverMode != .excluded else { return selection }
        selection.front = selection.front ?? domain.first?.number
        if book.coverArtwork == .spread && coverMode == .separate {
            selection.insideFront = selection.insideFront ?? (domain.count>1 ? domain[1].number : 0)
            selection.insideBack = 0; selection.back = 0
        } else {
            selection.insideFront = selection.insideFront ?? (domain.count>=4 ? domain[1].number : 0)
            selection.insideBack = selection.insideBack ?? (domain.count>=4 ? domain[domain.count-2].number : 0)
            selection.back = selection.back ?? domain.last?.number
        }
        return selection
    }
    public var bookInteriorPages: [SourcePage] {
        guard let book else { return pages }
        let candidates = pages.filter { !book.auxiliaryPages.contains($0.number) && !book.coverPDFPages.contains($0.number) }
        if coverMode == .separate { return candidates }
        let selection = resolvedCoverSelection
        let covers = Set([selection.front,selection.insideFront,selection.insideBack,selection.back].compactMap { $0 }.filter { $0>0 })
        return candidates.filter { !covers.contains($0.number) }
    }
}

extension Project {
    /// Explicit edge-to-edge booklet setup: trim/fold geometry uses the user's
    /// gutter unchanged, while bleed is clipped to the physical sheet.
    public var usesFullSheetBooklet: Bool {
        guard isBooklet || bookCoverTemplate else { return false }
        let m = sheet.margins,e = exportMarks
        return sheet.gripperWidth == 0 && [m.left,m.right,m.top,m.bottom].allSatisfy { $0 == 0 } &&
            !hasActiveCropMarks && !e.fold && !e.bleed && !e.safeArea && !e.pageNumbers && !e.sheetInfo && !e.fullCut && !e.colorBar && !e.registrationTargets
    }
    public var hasActiveCropMarks: Bool { exportMarks.crop && settings.cropMarkLength>0 }
    var clipsArtworkToSheet: Bool { usesFullSheetBooklet || autoLayout?.clipBleedToSheet == true }
    /// Keep fit calculations, placement and diagnostics on the same exterior reserve.
    var layoutExteriorReserve: Double {
        if usesFullSheetBooklet { return 0 }
        let s = settings
        let crop = s.cropMarkLength>0 && (!(isBooklet || bookCoverTemplate) || exportMarks.crop) ? s.cropMarkOffset+s.cropMarkLength : 0
        if binding == .stepAndRepeat { return max(clipsArtworkToSheet ? 0 : s.bleed,crop) }
        return max(clipsArtworkToSheet ? 0 : s.bleed,crop)
    }
}
