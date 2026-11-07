import Foundation

public struct SerialField: Identifiable, Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case sequential, stack }
    public enum Sides: String, Codable, Sendable { case front, back, both }
    public var id: UUID
    /// Zero-based page-pair job; numbering restarts independently for each job.
    public var jobIndex: Int
    public var start: Int64
    public var step: Int64
    public var digits: Int
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
        self.prefix = prefix; self.suffix = suffix; self.font = font; self.size = size; self.color = color
        self.rotation = rotation; self.sides = sides; self.position = position; self.mode = mode
    }
    public func value(at index: Int) -> Int64? {
        let product = step.multipliedReportingOverflow(by: Int64(index))
        let sum = start.addingReportingOverflow(product.partialValue)
        return product.overflow || sum.overflow ? nil : sum.partialValue
    }
    public func text(at index: Int) -> String? {
        guard let value = value(at: index) else { return nil }
        let number = String(value.magnitude)
        return prefix+(value < 0 ? "-" : "")+String(repeating: "0",count: max(0,min(32,digits)-number.count))+number+suffix
    }
    public var isValid: Bool {
        jobIndex >= 0 && (0...32).contains(digits) && !font.isEmpty && font.count <= 200 &&
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
}
/// A compact plan recipe; physical repetitions are evaluated without allocating quantity-sized arrays.
public struct SerialNumberPlan: Equatable, Sendable {
    public var fields: [SerialField]
    public var quantity: Int
    public var capacity: Int
    public var sheetCount: Int
    public init(fields: [SerialField],quantity: Int,capacity: Int,sheetCount: Int) {
        self.fields = fields; self.quantity = quantity; self.capacity = capacity
        self.sheetCount = sheetCount
    }
    public func ordinal(copy: Int,repetition: Int,mode: SerialField.Mode) -> Int? {
        guard copy >= 0,copy < capacity,repetition >= 0,repetition < sheetCount else { return nil }
        let index = mode == .sequential ? repetition*capacity+copy : copy*sheetCount+repetition
        return index < quantity ? index : nil
    }
    public func placements(slot: Slot,slotIndex: Int,kind: SideKind,repetition: Int) -> [SerialPlacement] {
        guard let copy = slot.copyIndex else { return [] }
        // On same-plate work, a press face contains both item fronts and backs.
        let itemFront = (slot.itemSide ?? kind) == .front
        return fields.compactMap { field in
            guard field.sides == .both || (field.sides == .front ? itemFront : !itemFront),
                  let index = ordinal(copy: copy,repetition: repetition,mode: field.mode),
                  let text = field.text(at: index) else { return nil }
            return SerialPlacement(field: field,slotIndex: slotIndex,index: index,text: text)
        }
    }
    public func placements(side: Side,kind: SideKind,repetition: Int) -> [SerialPlacement] {
        side.slots.enumerated().flatMap { placements(slot: $0.element,slotIndex: $0.offset,kind: kind,repetition: repetition) }
    }
    public func range(field: SerialField,repetition: Int) -> String? {
        guard repetition >= 0,repetition < sheetCount,capacity > 0 else { return nil }
        let first = field.mode == .sequential ? repetition*capacity : repetition
        guard first < quantity else { return nil }
        let last = field.mode == .sequential ? min(quantity-1,first+capacity-1) :
            first+min(capacity-1,(quantity-1-first)/sheetCount)*sheetCount
        guard let a = field.text(at: first), let b = field.text(at: last) else { return nil }
        return a+" – "+b
    }
}

extension ImpositionPlanner {
    /// Updates variable artwork without recalculating any slot geometry.
    public static func updatingSerials(in plan: ImpositionPlan,project: Project) -> ImpositionPlan {
        var next = plan
        next.issues.removeAll { $0.code == .serialNumbering }
        for index in next.sheets.indices { next.sheets[index].serialPlan = nil }
        applySerials(project,to: &next)
        return next
    }
    static func applySerials(_ project: Project,to plan: inout ImpositionPlan) {
        guard !project.serialFields.isEmpty else { return }
        guard project.binding == .stepAndRepeat else {
            plan.issues.append(ValidationIssue(.warning,.serialNumbering,"Seri numara alanları tekrarlı düz iş modunda kullanılır; ciltli işte basılmaz.")); return
        }
        guard project.serialFields.count <= 100,Set(project.serialFields.map(\.id)).count == project.serialFields.count,
              project.serialFields.allSatisfy(\.isValid) else {
            plan.issues.append(ValidationIssue(.error,.serialNumbering,"Seri numara alanları geçersiz (en fazla 100 alan; boyut 1–500 pt).")); return
        }
        for index in plan.sheets.indices {
            guard let layout = plan.sheets[index].repeatLayout else { continue }
            let fields = project.serialFields.filter { $0.jobIndex == layout.jobIndex }
            guard !fields.isEmpty else { continue }
            let count = layout.requestedQuantity ?? layout.copiesPerSheet
            guard fields.allSatisfy({ $0.value(at: count-1) != nil }) else {
                plan.issues.append(ValidationIssue(.error,.serialNumbering,"Seri numara aralığı 64 bit sayı sınırını aşıyor.")); continue
            }
            plan.sheets[index].serialPlan = SerialNumberPlan(fields: fields,quantity: count,capacity: layout.copiesPerSheet,
                sheetCount: plan.sheets[index].repeatCount)
            for field in fields {
                if let slot = plan.sheets[index].front.slots.first {
                    let width = slot.rotation%180 == 0 ? slot.size.width : slot.size.height
                    let height = slot.rotation%180 == 0 ? slot.size.height : slot.size.width
                    if field.position.x < 0 || field.position.y < 0 || field.position.x >= width || field.position.y >= height {
                        plan.issues.append(ValidationIssue(.warning,.serialNumbering,"Seri numara başlangıcı kesim dışında; metin kesim kutusuna kırpılır."))
                    }
                }
            }
        }
        if project.settings.turnMethod != .sheetwise {
            plan.issues.append(ValidationIssue(.warning,.serialNumbering,"Değişken seri numaralar ön/arka için farklı kalıp gerektirir; aynı kalıbı iki kez kullanmayın."))
        }
    }
}
