import Foundation

extension ImpositionPlan {
    /// Raw issues retain precise slot references; this cached presentation never grows with repetitions.
    public var displayIssues: [ValidationIssue] { groupedIssues ?? issues }
    public mutating func refreshWarningSummary(project: Project? = nil) {
        var output = issues.filter { $0.severity == .error }
        var groups: [String:[ValidationIssue]] = [:],order: [String] = []
        for issue in issues where issue.severity == .warning {
            let normalized = issue.message.replacingOccurrences(of: "^İş [0-9]+(?:, sayfa [0-9]+)?:\\s*",with: "",options: .regularExpression)
            let key = issue.code == .missingBleed ? "missingBleed" : "\(issue.code):\(normalized)"
            if groups[key] == nil { order.append(key) }
            groups[key,default: []].append(issue)
        }
        for key in order {
            guard let values = groups[key],var first = values.first else { continue }
            let refs = values.compactMap(\.slot)
            var pages = Set<Int>()
            for issue in values {
                if let ref = issue.slot,sheets.indices.contains(ref.sheet) {
                    let side = ref.side == .front ? sheets[ref.sheet].front : sheets[ref.sheet].back
                    if side.slots.indices.contains(ref.slot),let number = side.slots[ref.slot].sourcePageNumber { pages.insert(number) }
                } else if issue.message.hasPrefix("İş "),let word = issue.message.split(separator: " ").dropFirst().first,
                          let job = Int(word.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)),
                          let sheet = sheets.first(where: { $0.repeatLayout?.jobIndex == job-1 }),let layout = sheet.repeatLayout {
                    pages.insert(layout.frontPageNumber)
                    if let back = layout.backPageNumber { pages.insert(back) }
                }
            }
            if first.code == .missingBleed,pages.isEmpty,let project {
                pages.formUnion(project.pages.filter { ($0.availableBleed ?? -1) < project.settings.bleed }.map(\.number))
            }
            first.affectedPages = pages.sorted(); first.affectedSlots = refs; first.occurrenceCount = values.count
            if first.code == .missingBleed {
                first.message = "\(pages.count) sayfada taşma payı eksik: \(Self.pageRanges(pages.sorted()))"
            } else if values.count > 1 {
                let message = first.message.replacingOccurrences(of: "^İş [0-9]+(?:, sayfa [0-9]+)?:\\s*",with: "",options: .regularExpression)
                first.message = message+" (\(values.count) kez"+(pages.isEmpty ? ")" : "; sayfalar \(Self.pageRanges(pages.sorted())))")
            }
            output.append(first)
        }
        groupedIssues = output
    }
    private static func pageRanges(_ pages: [Int]) -> String {
        guard var start = pages.first else { return "—" }
        var end = start,parts: [String] = []
        for page in pages.dropFirst() {
            if page-end == 1 { end = page }
            else { parts.append(start == end ? "\(start)" : "\(start)-\(end)"); start = page; end = page }
        }
        parts.append(start == end ? "\(start)" : "\(start)-\(end)")
        return parts.joined(separator: ", ")
    }
}
