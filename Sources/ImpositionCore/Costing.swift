import Foundation

public enum PriceKind: String, Codable, CaseIterable, Sendable {
    case paper = "Kâğıt", digital = "Dijital", offset = "Ofset", finishing = "Cilt / işçilik"
}
public enum PriceUnit: String, Codable, CaseIterable, Sendable { case piece = "adet", sheet = "tabaka", job = "iş" }
/// No monetary defaults: nil is deliberately different from an explicit zero.
public struct PriceEntry: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var kind: PriceKind = .paper
    public var grammage: Double?
    public var size = Size(330,480)
    public var price: Decimal?
    public var perThousand = false
    public var includesVAT = false
    public var backPrice: Decimal?
    public var platePrice: Decimal?
    public var setupPrice: Decimal?
    public var colors: Int?
    public var unit: PriceUnit = .piece
    public init(kind: PriceKind = .paper, name: String = "") { self.kind = kind; self.name = name }
}
public struct PriceLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var entries: [PriceEntry] = []
    public var margin: Decimal?
    public var vat: Decimal?
    public init() {}
    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:data)
        guard value.version == 1,Set(value.entries.map(\.id)).count == value.entries.count else { throw CostError.invalidLibrary }
        return value
    }
    public func encoded() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; return try e.encode(self) }
}
public enum CostError: LocalizedError { case invalidLibrary, incomplete
    public var errorDescription: String? { self == .invalidLibrary ? "Fiyat tablosu sürümü veya kimlikleri geçersiz." : "Fiyat veya üretim bilgisi girilmedi; sonuç hesaplanamadı." }
}
public struct PriceSelection: Codable, Equatable, Sendable {
    public var id: UUID
    public var override: PriceEntry?
    public init(_ id: UUID) { self.id = id }
    public func resolved(in library: PriceLibrary) -> PriceEntry? { override ?? library.entries.first { $0.id == id } }
}
public struct QuoteSettings: Codable, Equatable, Sendable {
    public var company = ""
    public var logo: Data?
    public var jobName = ""
    public var validity = ""
    public var note = ""
    public var showCosts = false
    public init() {}
}
public struct JobCostSettings: Codable, Equatable, Sendable {
    public var paper: PriceSelection?
    public var printing: PriceSelection?
    public var finishing: [PriceSelection] = []
    public var margin: Decimal?
    public var vat: Decimal?
    /// Publication runs are not part of the legacy booklet planner. Explicit input only.
    public var copies: Int?
    public var extraWasteSheets = 0
    public var quote = QuoteSettings()
    public init() {}
}
public struct CostLine: Equatable, Sendable {
    public var name: String
    public var quantity: Decimal
    public var unitPrice: Decimal
    public var amount: Decimal { CostCalculator.round(quantity * unitPrice) }
}
public struct CostResult: Sendable {
    public var lines: [CostLine] = []
    public var missing: [String] = []
    public var sheets = 0
    public var quantity = 0
    public var cost: Decimal?
    public var profit: Decimal?
    public var tax: Decimal?
    public var sale: Decimal?
    public var perCopy: Decimal? { guard let sale,quantity > 0 else { return nil }; return CostCalculator.round(sale / Decimal(quantity)) }
}
public enum CostCalculator {
    public static func round(_ value: Decimal) -> Decimal { var a = value,b = Decimal(); NSDecimalRound(&b,&a,2,.plain); return b }
    public static func calculate(project: Project,plan: ImpositionPlan,library: PriceLibrary) -> CostResult {
        let settings = project.costing ?? JobCostSettings()
        var result = CostResult()
        let margin = settings.margin ?? library.margin, vat = settings.vat ?? library.vat
        if margin == nil || margin! < 0 { result.missing.append("Kâr marjı girilmedi") }
        if vat == nil || vat! < 0 { result.missing.append("KDV girilmedi") }
        let publication = project.isBooklet || project.isLeafBinding
        let run = publication ? settings.copies ?? 0 : 1
        if publication && run <= 0 { result.missing.append("Yayın adedi girilmedi") }
        let quantities: [Int]
        let finishingQuantities: [Int]
        if project.binding == .gang {
            let jobs = plan.sheets.first?.gangLayout?.jobs ?? []
            quantities = (project.gang?.jobs ?? []).map { job in jobs.first { $0.job.id == job.id }?.serialPlan.totalUnits(job.quantity) ?? job.quantity }
            finishingQuantities = (project.gang?.jobs ?? []).map { job in
                let total = job.waste.quantities(for:job.quantity)?.total ?? 0
                return jobs.first { $0.job.id == job.id }?.serialPlan.totalUnits(total) ?? total
            }
        } else if publication {
            quantities = [run]; finishingQuantities = [run]
        } else {
            quantities = plan.sheets.map { sheet in let total = sheet.repeatLayout?.requestedQuantity ?? sheet.repeatLayout?.copiesPerSheet ?? 0; return sheet.serialPlan?.totalUnits(total) ?? total }
            finishingQuantities = plan.sheets.map { sheet in let total = sheet.repeatLayout?.productionQuantity ?? sheet.repeatLayout?.requestedQuantity ?? sheet.repeatLayout?.copiesPerSheet ?? 0; return sheet.serialPlan?.totalUnits(total) ?? total }
        }
        func safeSum(_ values: [Int]) -> Int? {
            var total = 0
            for value in values { let sum = total.addingReportingOverflow(value); guard value >= 0,!sum.overflow else { return nil }; total = sum.partialValue }
            return total
        }
        guard let quantity = safeSum(quantities),let finished = safeSum(finishingQuantities),
              plan.canExport,!plan.sheets.isEmpty,plan.totalPressSheets != Int.max,run > 0,settings.extraWasteSheets >= 0 else {
            result.missing.append("Geçerli üretim planı girilmedi"); return result
        }
        result.quantity = quantity
        let multiplied = plan.totalPressSheets.multipliedReportingOverflow(by:run)
        let added = multiplied.partialValue.addingReportingOverflow(settings.extraWasteSheets)
        guard !multiplied.overflow,!added.overflow else { result.missing.append("Üretim adedi sayı sınırını aşıyor"); return result }
        let sheets = added.partialValue
        result.sheets = sheets
        func add(_ name: String,_ quantity: Decimal,_ price: Decimal?) {
            guard let price,price >= 0 else { result.missing.append("\(name): fiyat girilmedi"); return }
            result.lines.append(CostLine(name:name,quantity:quantity,unitPrice:price))
        }
        if let paper = settings.paper?.resolved(in:library),paper.kind == .paper {
            let fits = plan.sheets.allSatisfy { sameSize($0.size,paper.size) }
            if !fits { result.missing.append("Kâğıt tabaka boyutu planla eşleşmiyor") }
            var price = paper.price
            if paper.includesVAT { if let vat,vat >= 0 { price = price.map { $0 / (1 + vat/100) } } else { price = nil } }
            if paper.perThousand { price = price.map { $0 / 1000 } }
            add("Kâğıt: \(paper.name)",Decimal(sheets),price)
        } else { result.missing.append("Kâğıt fiyatı girilmedi") }
        let front = plan.sheets.filter { $0.hasContent(on:.front) }.reduce(0) { $0 + $1.repeatCount } * run
        let back = plan.sheets.filter { $0.hasContent(on:.back) }.reduce(0) { $0 + $1.repeatCount } * run
        let frontCount = front + (front > 0 ? settings.extraWasteSheets : 0)
        let backCount = back + (back > 0 ? settings.extraWasteSheets : 0)
        if let printing = settings.printing?.resolved(in:library) {
            if printing.kind == .digital {
                add("Dijital ön",Decimal(frontCount),printing.price)
                if backCount > 0 { add("Dijital arka",Decimal(backCount),printing.backPrice) }
            } else if printing.kind == .offset {
                if let colors = printing.colors,colors > 0,colors <= 32 {
                    let faces = plan.sheets.reduce(0) { n,s in n + (s.hasContent(on:.front) ? 1 : 0) + (s.hasContent(on:.back) && project.settings.turnMethod == .sheetwise ? 1 : 0) }
                    add("Ofset kalıp",Decimal(faces * colors),printing.platePrice)
                    add("Ofset hazırlık / ayar",Decimal(faces),printing.setupPrice)
                    add("Ofset baskı / 1000 tabaka geçişi",(Decimal(frontCount) + Decimal(backCount))/1000,printing.price)
                } else { result.missing.append("Ofset renk sayısı girilmedi") }
            } else { result.missing.append("Baskı fiyatı girilmedi") }
        } else { result.missing.append("Baskı fiyatı girilmedi") }
        for selection in settings.finishing {
            guard let entry = selection.resolved(in:library),entry.kind == .finishing else { result.missing.append("İşçilik fiyatı girilmedi"); continue }
            let count = entry.unit == .piece ? finished : entry.unit == .sheet ? sheets : 1
            add(entry.name,Decimal(count),entry.price)
        }
        if result.quantity <= 0 { result.missing.append("Adet girilmedi") }
        guard result.missing.isEmpty,let margin,let vat else { return result }
        let cost = result.lines.reduce(Decimal(0)) { $0 + $1.amount }
        let profit = round(cost * margin/100), net = cost + profit
        guard !cost.isNaN,!profit.isNaN,!net.isNaN else { result.missing.append("Fiyat sayı sınırını aşıyor"); return result }
        let tax = round(net * vat/100), sale = net + tax
        guard !tax.isNaN,!sale.isNaN else { result.missing.append("Fiyat sayı sınırını aşıyor"); return result }
        result.cost = cost; result.profit = profit; result.tax = tax; result.sale = sale
        return result
    }
    public static func sameSize(_ a: Size,_ b: Size) -> Bool { (abs(a.width-b.width)<0.01 && abs(a.height-b.height)<0.01) || (abs(a.width-b.height)<0.01 && abs(a.height-b.width)<0.01) }
}
public struct SheetComparison: Identifiable, Sendable {
    public var id: String { title }
    public var title: String
    public var project: Project
    public var result: CostResult
    public var paperPriced: Bool
    public var cheapest = false
}
public enum EconomicSheets {
    public static func compare(project: Project,library: PriceLibrary) -> [SheetComparison] {
        let selected = project.costing?.paper?.resolved(in:library)
        var rows: [SheetComparison] = []
        for preset in [SheetPreset.a3,.sra3,.cm33x48,.cm35x50,.cm50x70,.cm70x100] {
            var candidate = project
            candidate.sheet.size = preset.size
            var auto = candidate.autoLayout ?? AutoLayoutSettings()
            if let printing = candidate.costing?.printing?.resolved(in:library) { auto.production = printing.kind == .offset ? .offset : .digital }
            auto.sheetSelection = .fixed; auto.manualFields.insert(.sheetSize)
            candidate.autoLayout = auto
            let arranged = SmartAutoLayout.arrange(candidate)
            candidate = arranged.project
            let papers = library.entries.filter { $0.kind == .paper && CostCalculator.sameSize($0.size,preset.size) && (selected == nil || ($0.name == selected!.name && $0.grammage == selected!.grammage)) }
            let choices = papers.isEmpty ? [nil] : papers.map(Optional.some)
            var best: SheetComparison?
            for paper in choices {
                var settings = candidate.costing ?? JobCostSettings(); settings.paper = paper.map { PriceSelection($0.id) }; candidate.costing = settings
                let result = CostCalculator.calculate(project:candidate,plan:arranged.plan,library:library)
                let row = SheetComparison(title:preset.title,project:candidate,result:result,paperPriced:paper?.price != nil)
                if best == nil || (result.sale != nil && (best!.result.sale == nil || result.sale! < best!.result.sale!)) { best = row }
            }
            if let best { rows.append(best) }
        }
        if let index = rows.indices.filter({ rows[$0].result.sale != nil }).min(by:{ rows[$0].result.sale! < rows[$1].result.sale! }) { rows[index].cheapest = true }
        return rows
    }
}
