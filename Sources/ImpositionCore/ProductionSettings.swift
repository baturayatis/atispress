import Foundation

public struct WasteSettings: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case percent, fixed }
    public var mode: Mode = .percent
    public var percent: Double = 0
    public var fixed: Int = 0
    public var numberCopies = false
    public init() {}
    public func quantities(for quantity: Int) -> (waste: Int,total: Int)? {
        guard quantity > 0 else { return nil }
        let waste: Int
        if mode == .fixed { guard fixed >= 0 else { return nil }; waste = fixed }
        else {
            guard percent.isFinite,percent >= 0,let rate = Decimal(string: String(percent),locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            var value = Decimal(quantity)*rate/100,rounded = Decimal()
            NSDecimalRound(&rounded,&value,0,.up)
            guard let count = Int(NSDecimalNumber(decimal: rounded).stringValue),count >= 0 else { return nil }
            waste = count
        }
        let sum = quantity.addingReportingOverflow(waste)
        return sum.overflow ? nil : (waste,sum.partialValue)
    }
}
public enum PageLayout: String, Codable, Sendable { case automatic, duplex, simplex }
public struct PageJobOverride: Equatable, Codable, Sendable {
    public var frontPage: Int
    public var layout: PageLayout
    public init(frontPage: Int,layout: PageLayout) { self.frontPage = frontPage; self.layout = layout }
}
public struct PageLayoutSettings: Equatable, Codable, Sendable {
    public var mode: PageLayout = .automatic
    public var overrides: [PageJobOverride] = []
    public init() {}
}
public struct RepeatJob: Equatable, Sendable {
    public var front: SourcePage
    public var back: SourcePage?
    public var frontOnly: Bool
}
extension Project {
    public var resolvedPageLayout: PageLayout {
        guard let layout = stepAndRepeat.pageLayout else { return .duplex } // legacy intent
        guard layout.mode == .automatic else { return layout.mode }
        guard pages.count%2 == 0,let size = pages.first?.trimSize,
              pages.allSatisfy({ abs($0.trimSize.width-size.width) < 0.001 && abs($0.trimSize.height-size.height) < 0.001 }) else { return .simplex }
        return .duplex
    }
    /// Consumes selected pages exactly once. Splitting a duplex job preserves both
    /// pages as separate fronts; a duplex override consumes the next selected page.
    public var repeatJobs: [RepeatJob] {
        var output: [RepeatJob] = [],index = 0,splitNext = false
        let global = resolvedPageLayout
        while index < pages.count {
            let front = pages[index]
            let override = stepAndRepeat.pageLayout?.overrides.last(where: { $0.frontPage == front.number })?.layout
            let mode = override == .automatic || override == nil ? (splitNext ? .simplex : global) : override!
            let back = mode == .duplex && index+1 < pages.count ? pages[index+1] : nil
            output.append(RepeatJob(front: front,back: back,frontOnly: mode == .simplex))
            splitNext = !splitNext && global == .duplex && override == .simplex
            index += back == nil ? 1 : 2
        }
        return output
    }
}
extension Sheet {
    public var productionSummary: String? {
        guard let layout = repeatLayout else { return nil }
        let quantity = layout.requestedQuantity ?? layout.copiesPerSheet
        return "Adet \(quantity) + fire \(layout.wasteQuantity) = \(layout.productionQuantity ?? quantity) üretim, \(repeatCount) tabaka"
    }
    public var unnumberedCopiesDescription: String {
        guard let layout = repeatLayout else { return "0" }
        let produced = UInt64(repeatCount).multipliedReportingOverflow(by: UInt64(layout.copiesPerSheet))
        let count = UInt64(layout.numberedQuantity ?? layout.requestedQuantity ?? layout.copiesPerSheet)
        return produced.overflow || produced.partialValue < count ? "0" : String(produced.partialValue-count)
    }
}
public struct SheetInfoSettings: Equatable, Codable, Sendable {
    public var jobName: String? = nil
    public var showJobName = true
    public var date = true
    public var sheetNumber = true
    public var side = true
    public var sheetSize = true
    public var production = true
    public init() {}
}
