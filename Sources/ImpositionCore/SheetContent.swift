/// Production artwork determines whether a reverse exists. Guide/mark geometry
/// does not turn an otherwise empty reverse into printable content.
extension Sheet {
    public func hasContent(on kind: SideKind) -> Bool {
        let face = kind == .front ? front : back
        if face.slots.contains(where: { $0.sourcePageNumber != nil }) { return true }
        return !serialPlacements(side: face,kind: kind,repetition: 0).isEmpty
    }
}
extension ImpositionPlan {
    public var hasBackContent: Bool { sheets.contains { $0.hasContent(on: .back) } }
    public var hasBlankBacks: Bool { sheets.contains { !$0.hasContent(on: .back) } }
}
