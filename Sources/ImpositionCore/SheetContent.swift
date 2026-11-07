/// Production artwork determines whether a reverse exists. Guide/mark geometry
/// does not turn an otherwise empty reverse into printable content.
extension Sheet {
    public func hasContent(on kind: SideKind) -> Bool {
        let face = kind == .front ? front : back
        if face.slots.contains(where: { $0.sourcePageNumber != nil }) { return true }
        guard let serialPlan else { return false }
        // The earliest repetition contains every potentially numbered copy pile.
        return face.slots.enumerated().contains {
            !serialPlan.placements(slot: $0.element,slotIndex: $0.offset,kind: kind,repetition: 0).isEmpty
        }
    }
}
extension ImpositionPlan {
    public var hasBackContent: Bool { sheets.contains { $0.hasContent(on: .back) } }
    public var hasBlankBacks: Bool { sheets.contains { !$0.hasContent(on: .back) } }
}
