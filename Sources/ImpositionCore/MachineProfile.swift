import Foundation

public struct MachineProfile: Identifiable, Equatable, Codable, Sendable {
    public enum Rotation: String, CaseIterable, Codable, Sendable {
        case automatic, zero, ninety

        var angle: Int? {
            switch self {
            case .automatic: nil
            case .zero: 0
            case .ninety: 90
            }
        }
    }

    public enum Faces: String, CaseIterable, Codable, Sendable {
        case single, workAndTurn
    }

    public var id = UUID()
    public var name: String
    public var size: Size
    public var gripperEdge: Edge = .bottom
    public var gripperWidth: Double = 30
    public var gap: Double = 0
    public var rotation: Rotation?
    public var columns: Int?
    public var rows: Int?
    public var faces: Faces = .single

    public init(name: String, size: Size) {
        self.name = name
        self.size = size
    }

    public static let heidelberg: Self = {
        var profile = Self(name: "Heidelberg GTO 510x400", size: Size(510, 400))
        profile.id = UUID(uuidString: "2BE6FD4D-2387-4CAA-AC19-12FE5F048C88")!
        return profile
    }()

    public var hasManualLayout: Bool {
        rotation?.angle != nil && columns.map { (1...200).contains($0) } == true &&
            rows.map { (1...200).contains($0) } == true
    }

    func anchoredOrigin(in area: Rect, for block: Size) -> Point {
        var origin = Point(area.origin.x+(area.size.width-block.width)/2,
                           area.origin.y+(area.size.height-block.height)/2)
        switch gripperEdge {
        case .bottom: origin.y = area.origin.y
        case .top: origin.y = area.origin.y+area.size.height-block.height
        case .left: origin.x = area.origin.x
        case .right: origin.x = area.origin.x+area.size.width-block.width
        }
        return origin
    }

    public var isValid: Bool {
        let gripperAxis = gripperEdge == .left || gripperEdge == .right ? size.width : size.height
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            [size.width, size.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 10_000 } &&
            gripperWidth.isFinite && gripperWidth >= 0 && gripperWidth < gripperAxis &&
            gap.isFinite && (0...10_000).contains(gap)
    }
}

extension Project {
    public var supportsMachineProfile: Bool {
        !bookCoverTemplate && (binding == .stepAndRepeat || (binding == .gang && team == nil))
    }

    var activeMachineProfile: MachineProfile? {
        supportsMachineProfile ? machineProfile : nil
    }

    func applyingMachineProfile(_ profile: MachineProfile) -> Project {
        var input = self
        input.sheet = SheetSpec(size: profile.size, gripperEdge: profile.gripperEdge,
                                gripperWidth: profile.gripperWidth, gutter: profile.gap)
        input.alignment = .center
        input.stepAndRepeat.columns = profile.columns
        input.stepAndRepeat.rows = profile.rows
        input.settings.turnMethod = profile.faces == .single ? .sheetwise : .workAndTurn
        input.autoLayout?.trimTolerance = 0
        return input
    }
}
