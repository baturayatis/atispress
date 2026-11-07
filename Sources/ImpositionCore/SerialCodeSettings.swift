import Foundation

public struct SerialCodeSettings: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, qr, code128 }
    public enum Correction: String, Codable, Sendable, CaseIterable { case l = "L", m = "M", q = "Q", h = "H" }
    public var kind: Kind = .text
    public var template = "{no}"
    /// Total QR side / Code 128 width, including quiet zones, in mm.
    public var width: Double = 25
    /// Code 128 bar height in mm; QR is always square.
    public var height: Double = 15
    public var correction: Correction = .m
    public var quietZoneModules: Int? = nil
    public var humanReadable = false
    public var humanFontSize: Double = 8
    public init() {}
    public var quietZone: Int {
        get { quietZoneModules ?? (kind == .code128 ? 10 : 4) }
        set { quietZoneModules = newValue }
    }
    public func expanded(number: String) -> String { template.replacingOccurrences(of: "{no}",with: number) }
    public var isValid: Bool {
        width.isFinite && width > 0 && width <= 1_000_000 && height.isFinite && height > 0 && height <= 1_000_000 &&
        (0...1024).contains(quietZone) && humanFontSize.isFinite && (1...500).contains(humanFontSize)
    }
}
extension SerialField {
    public var kind: SerialCodeSettings.Kind {
        get { code?.kind ?? .text }
        set {
            var settings = code ?? SerialCodeSettings()
            if code == nil && newValue == .code128 { settings.width = 50 }
            settings.kind = newValue; code = settings
            if newValue != .text && color.components.count != 4 { color = .cmyk(0,0,0,1) }
        }
    }
    public var codeSettings: SerialCodeSettings {
        get { code ?? SerialCodeSettings() }
        set { code = newValue }
    }
    public var usesSerialNumber: Bool { kind == .text || codeSettings.template.contains("{no}") }
    public func content(at index: Int) -> String? {
        if !usesSerialNumber { return codeSettings.template }
        guard let number = text(at: index) else { return nil }
        return kind == .text ? number : codeSettings.expanded(number: number)
    }
}
extension SerialPlacement {
    public var content: String { field.kind == .text ? text : field.codeSettings.expanded(number: text) }
}
