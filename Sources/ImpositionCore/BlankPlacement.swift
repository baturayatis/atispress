import Foundation

/// One-based positions in the final padded interior reading order, never PDF page IDs.
public struct BlankPlacement: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case end, start, manual }
    public var mode: Mode = .end
    public var positions: [Int] = []
    public init() {}
}
struct PaddingOrder {
    var pages: [Int?]
    var positions: [Int]
    var issues: [ValidationIssue]
    static func make(project: Project,total: Int) -> PaddingOrder {
        let needed = total-project.pages.count,setting = project.blankPlacement ?? BlankPlacement()
        var positions: [Int],issues: [ValidationIssue] = []
        switch setting.mode {
        case .end: positions = Array((project.pages.count+1)..<(total+1))
        case .start: positions = Array(1..<(needed+1))
        case .manual:
            let valid = Set(setting.positions.filter { $0>0 && $0<=total })
            if valid.count != needed || valid.count != setting.positions.count {
                issues.append(ValidationIssue(.error,.invalidInput,"Elle boş sayfa seçimi: 1–\(total) arasında \(needed) farklı konum seçin; seçilen \(setting.positions.count). Eksikler önizlemede geçici olarak sona eklenir; çıktı engellenir."))
            }
            positions = Array(valid.sorted().prefix(needed))
            if positions.count<needed {
                var occupied = Set(positions)
                for index in (1..<(total+1)).reversed() where !occupied.contains(index) {
                    occupied.insert(index); positions.append(index)
                    if positions.count == needed { break }
                }
            }
            positions.sort()
        }
        let blanks = Set(positions)
        var source = project.pages.makeIterator()
        let pages = (1..<(total+1)).map { index -> Int? in blanks.contains(index) ? nil : source.next()?.number }
        return PaddingOrder(pages:pages,positions:positions,issues:issues)
    }
}
extension Sheet {
    public var blankPositions: [Int] {
        Array(Set((front.slots+back.slots).filter { $0.sourcePageNumber == nil }.compactMap { $0.logicalPageIndex.map { $0+1 } })).sorted()
    }
    public var signatureNumbers: [Int] { Array(Set((front.slots+back.slots).map { $0.signature+1 })).sorted() }
}
extension ImpositionPlan {
    public func pdfSideCount(includeBlankBacks: Bool = true) -> Int {
        let keepBlanks = includeBlankBacks && hasBackContent
        return sheets.reduce(0) { sum,sheet in
            let product = sheet.repeatCount.multipliedReportingOverflow(by:sheet.hasContent(on:.back) || keepBlanks ? 2 : 1)
            let addition = sum.addingReportingOverflow(product.partialValue)
            return product.overflow || addition.overflow ? Int.max : addition.partialValue
        }
    }
    public var paginationSummary: String {
        let blanks = blankPositions.isEmpty ? "Yok" : blankPositions.map(String.init).joined(separator:", ")
        return "\(signatureCount) forma (\(signaturePageCount) sayfa) · Eklenen boş: \(addedBlankPages) · Boş konumlar: \(blanks)"
    }
}
