import Foundation

public struct SpineContent: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case empty, color, text }
    public enum Position: String, CaseIterable, Codable, Sendable { case top, middle, bottom }
    public enum Alignment: String, CaseIterable, Codable, Sendable { case start, center, end }

    public struct TextBlock: Codable, Equatable, Sendable {
        public var text = ""
        public var font = "Helvetica"
        public var bold = false
        public var italic = false
        public var size = 12.0
        public var autoFit = false
        public var color = BleedColor.cmyk(0,0,0,1)
        public var alignment = Alignment.center
        public var bottomUp = false
        public var outlines = true
        public var x = 0.0
        public var y = 0.0
        public init() {}
    }

    public var mode = Mode.empty
    public var color = BleedColor.cmyk(0,0,0,1)
    public var extendEdges = false
    public var foldMarks = false
    public var blocks: [Position:TextBlock] = [:]
    public init() {}

    public var isValid: Bool { isValid(allowRGB:false) }

    func isValid(allowRGB: Bool) -> Bool {
        func validColor(_ color: BleedColor, rgb: Bool = false) -> Bool {
            guard rgb || color.components.count == 4 else { return false }
            return color.components.allSatisfy { (0...1).contains($0) }
        }
        return validColor(color,rgb:allowRGB) && blocks.values.allSatisfy {
            validColor($0.color) && (0.01...1000).contains($0.size) &&
                abs($0.x) <= 10_000 && abs($0.y) <= 10_000
        }
    }
}

public struct SpineArtwork: Equatable, Sendable {
    public var content: SpineContent
    public var backPage: Int?
    public var frontPage: Int?
    public var vectorExtension = false
    public var objects: [FreeSpineObject] = []
    public var clipLogosToTrim = false
}

public struct SpineLogo: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable { case pdf, png, jpg, convertedSVG }
    public let id: UUID
    public let name: String
    public let format: Format
    public let data: Data
    public var width: Double
    public var spineWidthPercent: Double?
    public var rotation = 0.0
    public var x = 0.0
    public var y = 0.0

    public init(name: String, format: Format, data: Data, width: Double) {
        self.id = UUID()
        self.name = name; self.format = format; self.data = data; self.width = width
    }
}

public struct SpineCalculation {
    public var pageCount: Int
    public var microns: Double?
    public var coverAllowance: Double
    public var glueAllowance: Double
    public init(pageCount: Int, microns: Double?, coverAllowance: Double, glueAllowance: Double) {
        self.pageCount = pageCount; self.microns = microns
        self.coverAllowance = coverAllowance; self.glueAllowance = glueAllowance
    }
    public var result: Double? {
        guard pageCount > 0, let microns, (0.01...10_000).contains(microns),
              (0...500).contains(coverAllowance), (0...500).contains(glueAllowance) else { return nil }
        let width = MeasuredSpineCalculator(coverAllowance: coverAllowance, adhesiveAllowance: glueAllowance)
            .thickness(pageCount: pageCount, stockCaliper: microns/1000)
        return width <= 1000 ? width : nil
    }
}
