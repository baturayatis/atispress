import Foundation

public struct FreeSpineObject: Codable, Equatable, Identifiable, Sendable {
    public enum Content: Codable, Equatable, Sendable {
        case text(SpineContent.TextBlock)
        case logo(SpineLogo)
    }

    public let id: UUID
    public var content: Content
    /// Retains the initial footprint (including fit and alignment) of old projects.
    public var legacyPosition: SpineContent.Position?
    public var textRotation = 0.0

    public init(id: UUID = UUID(), content: Content, legacyPosition: SpineContent.Position? = nil) {
        self.id = id; self.content = content; self.legacyPosition = legacyPosition
    }

    public var x: Double {
        get { switch content { case .text(let value): value.x; case .logo(let value): value.x } }
        set {
            switch content {
            case .text(var value): value.x = newValue; content = .text(value)
            case .logo(var value): value.x = newValue; content = .logo(value)
            }
        }
    }
    public var y: Double {
        get { switch content { case .text(let value): value.y; case .logo(let value): value.y } }
        set {
            switch content {
            case .text(var value): value.y = newValue; content = .text(value)
            case .logo(var value): value.y = newValue; content = .logo(value)
            }
        }
    }
    public var rotation: Double {
        get { if case .logo(let value) = content { return value.rotation }; return textRotation }
        set {
            if case .logo(var value) = content { value.rotation = newValue; content = .logo(value) }
            else { textRotation = newValue }
        }
    }
    public var size: Double {
        get { switch content { case .text(let value): value.size; case .logo(let value): value.width } }
        set {
            switch content {
            case .text(var value): value.size = newValue; value.autoFit = false; content = .text(value)
            case .logo(var value): value.width = newValue; content = .logo(value)
            }
        }
    }

    public var sizeRange: ClosedRange<Double> {
        if case .logo = content { return 0.001...10_000 }
        return 0.01...1000
    }

    var byteCount: Int {
        if case .logo(let logo) = content { return logo.data.count }
        return 0
    }

    var isValid: Bool {
        guard abs(x) <= 10_000, abs(y) <= 10_000, rotation.isFinite, sizeRange.contains(size) else { return false }
        if case .text(let text) = content {
            return text.text.utf8.count <= 16_000 && text.color.components.count == 4 &&
                text.color.components.allSatisfy { (0...1).contains($0) }
        }
        return byteCount <= 16*1024*1024
    }
}
