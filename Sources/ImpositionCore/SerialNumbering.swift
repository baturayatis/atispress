import Foundation

public struct SerialField: Identifiable, Equatable, Codable, Sendable {
    public enum Distribution: String, Codable, Sendable { case copy, block, job }
    public enum BackNumber: String, Codable, Sendable { case same, consecutive }
    public var rangeDistribution: Distribution? = nil
    public var backNumber: BackNumber? = nil
    public var distribution: Distribution { get { rangeDistribution ?? .copy } set { rangeDistribution = newValue } }
    public var backNumbering: BackNumber { get { backNumber ?? .same } set { backNumber = newValue } }
    public enum Mode: String, Codable, Sendable { case sequential, stack }
    public enum Sides: String, Codable, Sendable { case front, back, both }
    public var code: SerialCodeSettings? = nil
    public var id: UUID
    /// Zero-based page-pair job; numbering restarts independently for each job.
    public var jobIndex: Int
    public var start: Int64
    public var step: Int64
    public var digits: Int
    public var fixedDigits: Bool? = nil
    public var endNumberEnabled: Bool? = nil
    public var autoIncreasedDigits: Int? = nil
    public var prefix: String
    public var suffix: String
    public var font: String
    /// Typographic points. Position is the text baseline's left end, in local trim mm.
    public var size: Double
    public var color: BleedColor
    public var rotation: Double
    public var sides: Sides
    public var position: Point
    public var mode: Mode
    public init(id: UUID = UUID(),jobIndex: Int = 0,start: Int64 = 1,step: Int64 = 1,digits: Int = 4,
                prefix: String = "",suffix: String = "",font: String = "Helvetica",size: Double = 12,
                color: BleedColor = .cmyk(0,0,0,1),rotation: Double = 0,sides: Sides = .front,
                position: Point = Point(5,5),mode: Mode = .sequential) {
        self.id = id; self.jobIndex = jobIndex; self.start = start; self.step = step; self.digits = digits
        self.fixedDigits = false
        self.prefix = prefix; self.suffix = suffix; self.font = font; self.size = size; self.color = color
        self.rotation = rotation; self.sides = sides; self.position = position; self.mode = mode
    }
    public func value(at index: Int) -> Int64? {
        guard index >= 0 else { return nil }
        let product = step.magnitude.multipliedReportingOverflow(by: UInt64(index))
        guard !product.overflow else { return nil }
        let sign: Bool, magnitude: UInt64
        if (start < 0) == (step < 0) {
            let sum = start.magnitude.addingReportingOverflow(product.partialValue)
            guard !sum.overflow else { return nil }
            magnitude = sum.partialValue; sign = start < 0
        } else if start.magnitude >= product.partialValue {
            magnitude = start.magnitude-product.partialValue; sign = start < 0
        } else {
            magnitude = product.partialValue-start.magnitude; sign = step < 0
        }
        if sign,magnitude == UInt64(Int64.max)+1 { return Int64.min }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return sign ? -Int64(magnitude) : Int64(magnitude)
    }
    public func text(at index: Int) -> String? {
        guard let value = value(at: index) else { return nil }
        let number = String(value.magnitude)
        return prefix+(value < 0 ? "-" : "")+String(repeating: "0",count: max(0,min(32,digits)-number.count))+number+suffix
    }
    public var isValid: Bool {
        (kind == .text || codeSettings.isValid) && jobIndex >= 0 && (0...32).contains(digits) && !font.isEmpty && font.count <= 200 &&
        prefix.count <= 256 && suffix.count <= 256 && size.isFinite && (1...500).contains(size) &&
        rotation.isFinite && abs(rotation) <= 3600 && position.x.isFinite && position.y.isFinite &&
        abs(position.x) <= 1_000_000 && abs(position.y) <= 1_000_000 &&
        color.components.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

public struct SerialPlacement: Equatable, Sendable {
    public var field: SerialField
    public var slotIndex: Int
    public var index: Int
    public var text: String
    public var position: Point { field.position }
    public init(field: SerialField,slotIndex: Int,index: Int,text: String) {
        self.field = field; self.slotIndex = slotIndex; self.index = index; self.text = text
    }
}
/// A compact plan recipe; physical repetitions are evaluated without allocating quantity-sized arrays.
public struct SerialNumberPlan: Equatable, Sendable {
    /// One capacity per independent block. Empty preserves legacy copy numbering.
    public var blockCapacities: [Int] = []
    public var frontOnly = false
    public var fields: [SerialField]
    public var quantity: Int
    public var capacity: Int
    public var sheetCount: Int
    public init(fields: [SerialField],quantity: Int,capacity: Int,sheetCount: Int) {
        self.fields = fields.map { $0.adjustedDigits(quantity: quantity) }; self.quantity = quantity; self.capacity = capacity
        self.sheetCount = sheetCount
    }
    private func ordinal(copy: Int,repetition: Int,mode: SerialField.Mode,capacity: Int,sheets: Int? = nil) -> Int? {
        let sheetCount = sheets ?? self.sheetCount
        guard copy >= 0,copy < capacity,repetition >= 0,repetition < sheetCount else { return nil }
        let product = mode == .sequential ? repetition.multipliedReportingOverflow(by: capacity) : copy.multipliedReportingOverflow(by: sheetCount)
        let sum = product.partialValue.addingReportingOverflow(mode == .sequential ? copy : repetition)
        guard !product.overflow,!sum.overflow,sum.partialValue < quantity else { return nil }
        return sum.partialValue
    }
    public func ordinal(copy: Int,repetition: Int,mode: SerialField.Mode) -> Int? {
        ordinal(copy:copy,repetition:repetition,mode:mode,capacity:capacity)
    }
    public func numberIndex(field: SerialField,slot: Slot,kind: SideKind,repetition: Int) -> Int? {
        guard let copy = slot.copyIndex else { return nil }
        let index: Int
        if field.distribution == .block {
            let block = slot.serialBlockIndex ?? copy
            let local = slot.serialCopyIndex ?? 0
            let cap = blockCapacities.indices.contains(block) ? blockCapacities[block] : 1
            guard let ordinal = ordinal(copy:local,repetition:repetition,mode:field.mode,capacity:cap,sheets:cap>0 ? 1+(quantity-1)/cap : 0) else { return nil }
            let offset = block.multipliedReportingOverflow(by:quantity)
            let sum = offset.partialValue.addingReportingOverflow(ordinal)
            guard !offset.overflow,!sum.overflow else { return nil }; index = sum.partialValue
        } else {
            guard let ordinal = ordinal(copy:copy,repetition:repetition,mode:field.mode) else { return nil }; index = ordinal
        }
        if field.backNumbering == .consecutive && !frontOnly {
            let doubled = index.multipliedReportingOverflow(by:2)
            let sum = doubled.partialValue.addingReportingOverflow((slot.itemSide ?? kind) == .front ? 0 : 1)
            guard !doubled.overflow,!sum.overflow else { return nil }; return sum.partialValue
        }
        return index
    }
    public mutating func resolveDigits() {
        let snapshot = self
        fields = fields.map { $0.adjustedDigits(quantity:snapshot.numberCount(for:$0) ?? quantity) }
    }
    public var quantityMultiplier: Int {
        fields.contains { $0.distribution == .block } ? max(1,blockCapacities.isEmpty ? capacity : blockCapacities.count) : 1
    }
    public func totalUnits(_ count:Int) -> Int {
        let total = count.multipliedReportingOverflow(by:quantityMultiplier)
        return total.overflow ? Int.max : total.partialValue
    }
    public func numberCount(for field: SerialField) -> Int? {
        let blocks = field.distribution == .block ? max(1,blockCapacities.isEmpty ? capacity : blockCapacities.count) : 1
        let count = quantity.multipliedReportingOverflow(by:blocks)
        let doubled = count.partialValue.multipliedReportingOverflow(by:field.backNumbering == .consecutive && !frontOnly ? 2 : 1)
        return count.overflow || doubled.overflow ? nil : doubled.partialValue
    }
    public func blockRanges(field: SerialField) -> [String] {
        guard field.distribution == .block else { return [] }
        let count = max(1,blockCapacities.isEmpty ? capacity : blockCapacities.count)
        let multiplier = field.backNumbering == .consecutive && !frontOnly ? 2 : 1
        return (0..<count).map { block in
            let begin = block.multipliedReportingOverflow(by:quantity)
            let end = begin.partialValue.addingReportingOverflow(quantity-1)
            let a = begin.partialValue.multipliedReportingOverflow(by:multiplier)
            let b = end.partialValue.multipliedReportingOverflow(by:multiplier)
            let last = b.partialValue.addingReportingOverflow(multiplier-1)
            guard !begin.overflow,!end.overflow,!a.overflow,!b.overflow,!last.overflow,
                  let first = field.text(at:a.partialValue),let final = field.text(at:last.partialValue) else { return "Blok \(block+1): sayısal kapasite aşıldı" }
            return "Blok \(block+1): \(first) – \(final)"
        }
    }
    public func placements(slot: Slot,slotIndex: Int,kind: SideKind,repetition: Int) -> [SerialPlacement] {
        guard slot.copyIndex != nil else { return [] }
        // On same-plate work, a press face contains both item fronts and backs.
        let itemFront = (slot.itemSide ?? kind) == .front
        if frontOnly && !itemFront { return [] }
        return fields.compactMap { original in
            let field = original.adjustedDigits(quantity:numberCount(for:original) ?? quantity)
            guard field.sides == .both || (field.sides == .front ? itemFront : !itemFront),
                  let index = numberIndex(field:field,slot:slot,kind:kind,repetition:repetition),
                  let text = field.text(at: index) ?? (field.usesSerialNumber ? nil : "") else { return nil }
            return SerialPlacement(field: field.adjustedDigits(quantity:numberCount(for:field) ?? quantity),slotIndex: slotIndex,index: index,text: text)
        }
    }
    public func placements(side: Side,kind: SideKind,repetition: Int) -> [SerialPlacement] {
        side.slots.enumerated().flatMap { placements(slot: $0.element,slotIndex: $0.offset,kind: kind,repetition: repetition) }
    }
    public func range(field: SerialField,repetition: Int) -> String? {
        if field.distribution == .block { return blockRanges(field:field).joined(separator:" · ") }
        guard repetition >= 0,repetition < sheetCount,capacity > 0 else { return nil }
        guard let first = ordinal(copy: 0,repetition: repetition,mode: field.mode) else { return nil }
        if !field.usesSerialNumber { return field.codeSettings.template }
        let last = field.mode == .sequential ? first+min(capacity-1,quantity-1-first) :
            first+min(capacity-1,(quantity-1-first)/sheetCount)*sheetCount
        let multiplier = field.backNumbering == .consecutive && !frontOnly ? 2 : 1
        let start = first.multipliedReportingOverflow(by:multiplier),end = last.multipliedReportingOverflow(by:multiplier)
        let final = end.partialValue.addingReportingOverflow(multiplier-1)
        guard !start.overflow,!end.overflow,!final.overflow,let a = field.text(at:start.partialValue),let b = field.text(at:final.partialValue) else { return nil }
        return a+" – "+b
    }
}

/// Identical block counters continue across jobs on the same production plan.
/// Different starts are explicit domains and are checked for range overlap.
struct SerialBlockAllocator {
    private struct Key: Hashable {
        var start: Int64
        var step: Int64
        var prefix: String
        var suffix: String
        var back: String
    }
    private var offsets: [Key:Int] = [:]
    mutating func allocate(_ fields:[SerialField],quantity:Int,blocks:Int,frontOnly:Bool) -> (fields:[SerialField],overflow:Bool) {
        let previous = offsets
        var failed = false
        let adjusted = fields.map { field -> SerialField in
            guard field.distribution == .block,field.usesSerialNumber else { return field }
            let key = Key(start:field.start,step:field.step,prefix:field.prefix,suffix:field.suffix,back:field.backNumbering.rawValue)
            let offset = previous[key] ?? 0
            let items = quantity.multipliedReportingOverflow(by:blocks)
            let numbers = items.partialValue.multipliedReportingOverflow(by:field.backNumbering == .consecutive && !frontOnly ? 2 : 1)
            let end = offset.addingReportingOverflow(numbers.partialValue)
            guard !items.overflow,!numbers.overflow,!end.overflow,let start = field.value(at:offset) else { failed = true; return field }
            offsets[key] = end.partialValue
            var shifted = field; shifted.start = start
            return shifted
        }
        return (adjusted,failed)
    }
}

extension ImpositionPlanner {
    /// Updates variable artwork without recalculating any slot geometry.
    public static func updatingSerials(in plan: ImpositionPlan,project: Project) -> ImpositionPlan {
        if project.binding == .gang,let sheet = plan.sheets.first,let layout = sheet.gangLayout {
            // Artwork-only changes reuse the exact slicing solution; numbering stays lazy.
            var snapshot = project
            snapshot.gang?.mode = .manual; snapshot.gang?.blocks = layout.blocks
            snapshot.sheet.size = sheet.size
            snapshot.sheet.orientation = sheet.size.width > sheet.size.height ? .landscape : .portrait
            return self.plan(snapshot)
        }
        let wasBlock = plan.sheets.contains { $0.serialPlan?.fields.contains { $0.distribution == .block } == true }
        let isBlock = project.serialFields.contains { $0.distribution == .block }
        if wasBlock != isBlock { return self.plan(project) }
        var next = plan
        next.issues.removeAll { $0.code == .serialNumbering }
        for index in next.sheets.indices { next.sheets[index].serialPlan = nil }
        applySerials(project,to: &next)
        next.refreshWarningSummary(project: project)
        return next
    }
    static func applySerials(_ project: Project,to plan: inout ImpositionPlan) {
        guard project.binding != .gang, !project.serialFields.isEmpty else { return }
        guard project.binding == .stepAndRepeat else {
            plan.issues.append(ValidationIssue(.warning,.serialNumbering,"Seri numara alanları tekrarlı düz iş modunda kullanılır; ciltli işte basılmaz.")); return
        }
        guard project.serialFields.count <= 100,Set(project.serialFields.map(\.id)).count == project.serialFields.count,
              project.serialFields.allSatisfy(\.isValid) else {
            plan.issues.append(ValidationIssue(.error,.serialNumbering,"Seri alan ayarları geçersiz: en fazla 100 alan, yazı boyutu 1–500 pt, pozitif kod ölçüsü ve sessiz alan 0–1024 modül olmalıdır.")); return
        }
        var allocator = SerialBlockAllocator()
        for index in plan.sheets.indices {
            guard let layout = plan.sheets[index].repeatLayout else { continue }
            var fields = project.serialFields.filter { $0.jobIndex == layout.jobIndex }.map { $0.adjustedDigits(quantity: layout.numberedQuantity ?? layout.requestedQuantity ?? layout.copiesPerSheet) }
            guard !fields.isEmpty else { continue }
            let count = layout.numberedQuantity ?? layout.requestedQuantity ?? layout.copiesPerSheet
            let allocated = allocator.allocate(fields,quantity:count,blocks:layout.copiesPerSheet,frontOnly:layout.frontOnly)
            fields = allocated.fields
            if allocated.overflow { plan.issues.append(ValidationIssue(.error,.serialNumbering,"Blok aralığı sayısal kapasiteyi aşıyor.")) }
            guard fields.allSatisfy({ !$0.usesSerialNumber || $0.value(at: count-1) != nil }) else {
                plan.issues.append(ValidationIssue(.error,.serialNumbering,"Seri numara aralığı 64 bit sayı sınırını aşıyor.")); continue
            }
            plan.sheets[index].serialPlan = SerialNumberPlan(fields: fields,quantity: count,capacity: layout.copiesPerSheet,
                sheetCount: plan.sheets[index].repeatCount)
            if fields.contains(where:{ $0.distribution == .block }) {
                plan.sheets[index].repeatCount = max(count,layout.productionQuantity ?? count)
                plan.sheets[index].serialPlan?.sheetCount = max(count,layout.productionQuantity ?? count)
                plan.sheets[index].serialPlan?.blockCapacities = Array(repeating:1,count:layout.copiesPerSheet)
            }
            plan.sheets[index].serialPlan?.frontOnly = layout.frontOnly
            plan.sheets[index].serialPlan?.resolveDigits()
            if let recipe = plan.sheets[index].serialPlan {
                for field in fields {
                    guard let total = recipe.numberCount(for:field),total>0,!field.usesSerialNumber || field.value(at:total-1) != nil else {
                        plan.issues.append(ValidationIssue(.error,.serialNumbering,"Seri numara aralığı sayısal kapasiteyi aşıyor.")); continue
                    }
                    if field.usesSerialNumber,(field.distribution != .copy || field.backNumbering == .consecutive),field.digitsAreManual,(field.requiredDigits(quantity:total) ?? 33)>field.digits {
                        plan.issues.append(ValidationIssue(.error,.serialNumbering,"Seri aralığı sabit basamak sayısını aşıyor."))
                    }
                    if field.usesSerialNumber,field.distribution == .block,field.step == 0 {
                        plan.issues.append(ValidationIssue(.error,.serialNumbering,"Blok aralıkları çakışıyor: artış sıfır olamaz."))
                    }
                }
            }
            for field in fields {
                if layout.frontOnly && field.sides == .back { plan.issues.append(ValidationIssue(.warning,.serialNumbering,"Tek yüz işte arka seri numara alanı basılmaz.")) }
                if field.digitsAreManual,let required = field.requiredDigits(quantity: count),required > field.digits {
                    plan.issues.append(ValidationIssue(.warning,.serialNumbering,field.digitNote(quantity: count)!))
                }
                if let slot = plan.sheets[index].front.slots.first {
                    let width = slot.rotation%180 == 0 ? slot.size.width : slot.size.height
                    let height = slot.rotation%180 == 0 ? slot.size.height : slot.size.width
                    if field.position.x < 0 || field.position.y < 0 || field.position.x >= width || field.position.y >= height {
                        plan.issues.append(ValidationIssue(.warning,.serialNumbering,"Seri numara başlangıcı kesim dışında; metin kesim kutusuna kırpılır."))
                    }
                }
            }
        }
        let recipes = plan.sheets.compactMap { sheet -> (Int,SerialNumberPlan)? in
            guard let job = sheet.repeatLayout?.jobIndex,let recipe = sheet.serialPlan else { return nil }; return (job,recipe)
        }
        for a in recipes.indices { for b in recipes.indices where b>a && recipes[a].0 != recipes[b].0 {
            for first in recipes[a].1.fields where first.distribution != .copy && first.usesSerialNumber {
                for second in recipes[b].1.fields where second.distribution == first.distribution && second.usesSerialNumber && first.prefix == second.prefix && first.suffix == second.suffix {
                    if let ca = recipes[a].1.numberCount(for:first),let cb = recipes[b].1.numberCount(for:second),
                       let ae = first.value(at:ca-1),let be = second.value(at:cb-1),
                       max(min(first.start,ae),min(second.start,be)) <= min(max(first.start,ae),max(second.start,be)) {
                        plan.issues.append(ValidationIssue(.error,.serialNumbering,"Blok/iş seri aralıkları çakışıyor: İş \(recipes[a].0+1) / İş \(recipes[b].0+1)."))
                    }
                }
            }
        } }
        if project.settings.turnMethod != .sheetwise {
            plan.issues.append(ValidationIssue(.warning,.serialNumbering,"Değişken seri numaralar ön/arka için farklı kalıp gerektirir; aynı kalıbı iki kez kullanmayın."))
        }
    }
}
