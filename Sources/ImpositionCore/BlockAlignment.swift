public enum BlockAlignment: String, Codable, Sendable { case center, gripper }
extension Project {
    /// Absent in older projects and legacy API callers: retain their exact geometry.
    public var blockAlignment: BlockAlignment {
        get { alignment ?? .gripper }
        set { alignment = newValue }
    }
}
extension ImpositionPlanner {
    static func usableMargins(_ spec: SheetSpec) -> Insets {
        var m = spec.margins
        switch spec.gripperEdge {
        case .left: m.left += spec.gripperWidth
        case .right: m.right += spec.gripperWidth
        case .top: m.top += spec.gripperWidth
        case .bottom: m.bottom += spec.gripperWidth
        }
        return m
    }
}
