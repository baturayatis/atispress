public struct ColorControlSettings: Equatable, Codable, Sendable {
    public enum BarSide: String, Codable, Sendable { case gripper, opposite }
    public var colorBar = false
    public var targets = false
    /// Circle diameter / crosshair span, in mm. Stroke is added outside it.
    public var targetSize: Double = 5
    /// Square vector patches, in mm.
    public var patchSize: Double = 5
    public var barSide: BarSide = .gripper
    public init() {}
}
extension ExportMarks {
    public var colorBar: Bool {
        get { colorControls?.colorBar ?? false }
        set { var value = colorControls ?? ColorControlSettings(); value.colorBar = newValue; colorControls = value }
    }
    public var registrationTargets: Bool {
        get { colorControls?.targets ?? false }
        set { var value = colorControls ?? ColorControlSettings(); value.targets = newValue; colorControls = value }
    }
    public var targetSize: Double {
        get { colorControls?.targetSize ?? 5 }
        set { var value = colorControls ?? ColorControlSettings(); value.targetSize = newValue; colorControls = value }
    }
    public var patchSize: Double {
        get { colorControls?.patchSize ?? 5 }
        set { var value = colorControls ?? ColorControlSettings(); value.patchSize = newValue; colorControls = value }
    }
    public var barSide: ColorControlSettings.BarSide {
        get { colorControls?.barSide ?? .gripper }
        set { var value = colorControls ?? ColorControlSettings(); value.barSide = newValue; colorControls = value }
    }
}
