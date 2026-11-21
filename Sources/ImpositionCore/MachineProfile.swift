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
    public var rotation: Rotation? = .zero
    public var columns: Int? = 1
    public var rows: Int? = 1
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

    public var withLayoutDefaults: Self {
        var profile = self
        if profile.rotation?.angle == nil { profile.rotation = .zero }
        profile.columns = profile.columns ?? 1
        profile.rows = profile.rows ?? 1
        return profile
    }

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

    public var sharedSheetOrientation: Orientation {
        (autoLayout ?? .legacy).isFixed(.orientation) ? sheet.orientation : .auto
    }

    public var sharedSheet: SheetSpec {
        var stock = sheet
        stock.orientation = sharedSheetOrientation
        if let profile = machineProfile {
            if autoLayout?.usesExplicitSheet != true { stock.size = profile.size }
            if autoLayout?.isFixed(.marginLeft) != true { stock.margins.left = 0 }
            if autoLayout?.isFixed(.marginRight) != true { stock.margins.right = 0 }
            if autoLayout?.isFixed(.marginTop) != true { stock.margins.top = 0 }
            if autoLayout?.isFixed(.marginBottom) != true { stock.margins.bottom = 0 }
            stock.gripperEdge = profile.gripperEdge
            stock.gripperWidth = profile.gripperWidth
        }
        return stock
    }

    public mutating func setSharedSheetSize(_ size: Size) {
        var state = autoLayout ?? .legacy
        state.usesExplicitSheet = true
        state.sheetSelection = .fixed
        state.manualFields.insert(.sheetSize)
        state.automaticFields.remove(.sheetSize)
        state.presetFields?.remove(.sheetSize)
        state.summary = nil
        autoLayout = state
        sheet.size = size
    }

    var activeMachineProfile: MachineProfile? {
        guard supportsMachineProfile, var profile = machineProfile?.withLayoutDefaults else { return nil }
        let stock = sharedSheet
        profile.size = stock.size.oriented(stock.orientation)
        return profile
    }

    func machineExteriorReserve(bleed: Double) -> Double {
        guard settings.cropMarkLength > 0 else { return max(layoutExteriorReserve, bleed) }
        let halfStroke = max(0.01, exportMarks.lineWidth.isFinite ? exportMarks.lineWidth : 0.25)*25.4/144
        return max(layoutExteriorReserve, bleed+settings.cropMarkLength+halfStroke)
    }

    func applyingMachineProfile(_ profile: MachineProfile) -> Project {
        var input = self
        input.alignment = .center
        if coverGrid == nil {
            input.sheet = sharedSheet
            input.sheet.size = profile.size
            input.sheet.gutter = profile.gap
            input.stepAndRepeat.columns = profile.columns
            input.stepAndRepeat.rows = profile.rows
            input.settings.turnMethod = profile.faces == .single ? .sheetwise : .workAndTurn
        }
        input.autoLayout?.trimTolerance = 0
        return input
    }
}
