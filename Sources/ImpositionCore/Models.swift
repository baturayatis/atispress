import Foundation
/// All distances are millimetres. Coordinates originate at the sheet's bottom left.
public struct Size: Equatable, Sendable, Codable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
}
public struct Point: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}
/// Axis-aligned bounds in sheet millimetres. Shared with every plan consumer.
public struct Rect: Equatable, Sendable {
    public var origin: Point
    public var size: Size
    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point(x,y); size = Size(width,height)
    }
}
public struct Insets: Equatable, Sendable, Codable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double
    public init(left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }
}
public enum BindingMethod: String, Codable, Sendable { case saddleStitch, perfectBound, stepAndRepeat, gang, sewn, spiral, wireO }
public enum CoverMode: String, Codable, Sendable { case included, excluded, separate }
public enum BlankPagePolicy: String, Codable, Sendable { case append, reject }
public enum Orientation: String, Codable, Sendable { case auto, portrait, landscape }
public enum Edge: String, Codable, Sendable { case left, right, top, bottom }
public enum TurnMethod: String, Codable, Sendable { case sheetwise, workAndTurn, workAndTumble }
public enum SignatureSize: String, Codable, Sendable {
    case automatic, four, eight, sixteen, thirtyTwo
    public var pageCount: Int? {
        switch self { case .automatic: return nil; case .four: return 4; case .eight: return 8; case .sixteen: return 16; case .thirtyTwo: return 32 }
    }
}
public enum SheetPreset: Sendable {
    case a5, a4, a3, sra3, cm33x48, cm35x50, cm50x70, cm70x100
    public var title: String {
        switch self {
        case .a5: return "A5"
        case .a4: return "A4"
        case .a3: return "A3"
        case .sra3: return "SRA3"
        case .cm33x48: return "33×48"
        case .cm35x50: return "35×50"
        case .cm50x70: return "50×70"
        case .cm70x100: return "70×100"
        }
    }
    public var size: Size {
        switch self {
        case .a5: return Size(148, 210)
        case .a4: return Size(210, 297)
        case .a3: return Size(297, 420)
        case .sra3: return Size(320, 450)
        case .cm33x48: return Size(330, 480)
        case .cm35x50: return Size(350, 500)
        case .cm50x70: return Size(500, 700)
        case .cm70x100: return Size(700, 1000)
        }
    }
}
public struct SheetSpec: Equatable, Sendable, Codable {
    public var size: Size
    public var margins: Insets
    public var gripperEdge: Edge
    public var gripperWidth: Double
    public var gutter: Double
    public var orientation: Orientation
    public init(size: Size, margins: Insets = Insets(), gripperEdge: Edge = .bottom,
                gripperWidth: Double = 0, gutter: Double = 0, orientation: Orientation = .auto) {
        self.size = size; self.margins = margins; self.gripperEdge = gripperEdge
        self.gripperWidth = gripperWidth; self.gutter = gutter; self.orientation = orientation
    }
    public init(preset: SheetPreset, margins: Insets = Insets(), gripperEdge: Edge = .bottom,
                gripperWidth: Double = 0, gutter: Double = 0, orientation: Orientation = .auto) {
        self.init(size: preset.size, margins: margins, gripperEdge: gripperEdge,
                  gripperWidth: gripperWidth, gutter: gutter, orientation: orientation)
    }
}
public struct SourcePage: Equatable, Sendable, Codable {
    /// One-based identifier in the source document. Array order is the reading order.
    public var number: Int
    public var trimSize: Size
    /// Nil means unknown; PDFEngine will populate this later.
    public var availableBleed: Double?
    public init(number: Int, trimSize: Size, availableBleed: Double? = nil) {
        self.number = number; self.trimSize = trimSize; self.availableBleed = availableBleed
    }
}
public enum GeneratedBleedMethod: String, Codable, Sendable { case automatic, mirror, solidColor }
public enum BleedColor: Equatable, Sendable, Codable {
    case rgb(Double,Double,Double)
    case cmyk(Double,Double,Double,Double)
    public var components: [Double] {
        switch self { case .rgb(let r,let g,let b): return [r,g,b]; case .cmyk(let c,let m,let y,let k): return [c,m,y,k] }
    }
}
public struct GeneratedBleedSettings: Equatable, Sendable, Codable {
    public var enabled: Bool
    public var method: GeneratedBleedMethod
    /// Maximum per-channel range in a 0.5 mm edge strip, normalized to 0...1.
    public var tolerance: Double
    public var color: BleedColor
    public init(enabled: Bool = false,method: GeneratedBleedMethod = .automatic,tolerance: Double = 0.02,
                color: BleedColor = .cmyk(0,0,0,0)) {
        self.enabled = enabled; self.method = method; self.tolerance = tolerance; self.color = color
    }
    public var isValid: Bool {
        tolerance.isFinite && (0...1).contains(tolerance) && color.components.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}
public struct ImpositionSettings: Equatable, Sendable, Codable {
    public var bleed: Double
    public var cropMarkLength: Double
    public var cropMarkOffset: Double
    public var safeAreaInset: Double
    public var signatureSize: SignatureSize
    public var turnMethod: TurnMethod
    public var generatedBleed: GeneratedBleedSettings
    public init(bleed: Double = 3, cropMarkLength: Double = 5, cropMarkOffset: Double = 3,
                safeAreaInset: Double = 5, signatureSize: SignatureSize = .automatic,
                turnMethod: TurnMethod = .sheetwise,generatedBleed: GeneratedBleedSettings = GeneratedBleedSettings()) {
        self.bleed = bleed; self.cropMarkLength = cropMarkLength; self.cropMarkOffset = cropMarkOffset
        self.safeAreaInset = safeAreaInset; self.signatureSize = signatureSize; self.turnMethod = turnMethod
        self.generatedBleed = generatedBleed
    }
}
public enum RepeatArrangement: String, Codable, Sendable { case adjacent, spaced, custom }
/// Optional dimensions override the automatically fitted grid independently.
public struct StepAndRepeatSettings: Equatable, Sendable, Codable {
    /// Nil in legacy files preserves their existing gutter behavior.
    public var waste: WasteSettings? = nil
    public var pageLayout: PageLayoutSettings? = nil
    public var arrangement: RepeatArrangement? = nil
    public var columns: Int?
    public var rows: Int?
    public var allowRotation: Bool
    /// Finished pieces per page pair, not impressions. Nil means one full press sheet.
    public var quantity: Int?
    public init(columns: Int? = nil, rows: Int? = nil, allowRotation: Bool = true, quantity: Int? = nil, arrangement: RepeatArrangement = .adjacent) {
        self.arrangement = arrangement
        self.columns = columns; self.rows = rows; self.allowRotation = allowRotation; self.quantity = quantity
    }
}
public struct GridPosition: Equatable, Sendable {
    /// Zero-based indices, rows counted from the bottom in each face's viewing frame.
    public var column: Int
    public var row: Int
    public init(column: Int, row: Int) { self.column = column; self.row = row }
}
public struct RepeatLayout: Equatable, Sendable {
    public var jobIndex: Int
    public var frontPageNumber: Int
    public var backPageNumber: Int?
    public var columns: Int
    public var rows: Int
    public var productionQuantity: Int? = nil
    public var wasteQuantity: Int = 0
    public var numberedQuantity: Int? = nil
    public var frontOnly = false
    public var requestedQuantity: Int?
    public var copiesPerSheet: Int { columns * rows }
    public init(jobIndex: Int, frontPageNumber: Int, backPageNumber: Int?, columns: Int, rows: Int, requestedQuantity: Int?) {
        self.jobIndex = jobIndex; self.frontPageNumber = frontPageNumber; self.backPageNumber = backPageNumber
        self.columns = columns; self.rows = rows; self.requestedQuantity = requestedQuantity
    }
}
/// Production marks are independent of preview overlays. Stored with the project.
public struct ExportMarks: Equatable, Sendable, Codable {
    public enum Color: String, Codable, Sendable { case black, registration }
    public var colorControls: ColorControlSettings? = nil
    public var crop = true
    public var fold = false
    public var bleed = false
    public var safeArea = false
    public var pageNumbers = false
    public var sheetInfo = false
    public var fullCut = false
    public var lineWidth: Double = 0.25 // points
    public var color: Color = .black
    public init() {}
    public static var none: ExportMarks { var value = ExportMarks(); value.crop = false; return value }
}
public struct Project: Equatable, Sendable, Codable {
    var bookCoverTemplate = false
    public var alignment: BlockAlignment? = nil
    public var blankPlacement: BlankPlacement? = nil
    public var book: BookSettings? = nil
    public var gang: GangSettings? = nil
    public var sheetInfo: SheetInfoSettings? = nil
    public var includeBlankBacks: Bool? = nil
    public var autoLayout: AutoLayoutSettings? = nil
    public var serialFields: [SerialField] = []
    public var exportMarks = ExportMarks()
    public var pages: [SourcePage]
    public var blankPagePolicy: BlankPagePolicy
    public var binding: BindingMethod
    public var coverMode: CoverMode
    public var sheet: SheetSpec
    public var settings: ImpositionSettings
    public var stepAndRepeat: StepAndRepeatSettings
    public init(pages: [SourcePage], binding: BindingMethod = .stepAndRepeat, sheet: SheetSpec,
                blankPagePolicy: BlankPagePolicy = .append, coverMode: CoverMode = .included,
                settings: ImpositionSettings = ImpositionSettings(), stepAndRepeat: StepAndRepeatSettings = StepAndRepeatSettings()) {
        self.pages = pages; self.binding = binding; self.sheet = sheet
        self.blankPagePolicy = blankPagePolicy; self.coverMode = coverMode; self.settings = settings
        self.stepAndRepeat = stepAndRepeat
    }
    private enum CodingKeys: String, CodingKey {
        case alignment, blankPlacement, book, gang, sheetInfo, includeBlankBacks, autoLayout, serialFields, exportMarks, pages, blankPagePolicy, binding, coverMode, sheet, settings, stepAndRepeat
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alignment = try c.decodeIfPresent(BlockAlignment.self,forKey:.alignment)
        blankPlacement = try c.decodeIfPresent(BlankPlacement.self,forKey:.blankPlacement)
        book = try c.decodeIfPresent(BookSettings.self,forKey:.book)
        gang = try c.decodeIfPresent(GangSettings.self,forKey: .gang)
        sheetInfo = try c.decodeIfPresent(SheetInfoSettings.self,forKey: .sheetInfo)
        includeBlankBacks = try c.decodeIfPresent(Bool.self,forKey: .includeBlankBacks)
        autoLayout = try c.decodeIfPresent(AutoLayoutSettings.self,forKey: .autoLayout)
        serialFields = try c.decodeIfPresent([SerialField].self,forKey: .serialFields) ?? []
        exportMarks = try c.decode(ExportMarks.self,forKey: .exportMarks)
        pages = try c.decode([SourcePage].self,forKey: .pages)
        blankPagePolicy = try c.decode(BlankPagePolicy.self,forKey: .blankPagePolicy)
        binding = try c.decode(BindingMethod.self,forKey: .binding)
        coverMode = try c.decode(CoverMode.self,forKey: .coverMode)
        sheet = try c.decode(SheetSpec.self,forKey: .sheet)
        settings = try c.decode(ImpositionSettings.self,forKey: .settings)
        stepAndRepeat = try c.decode(StepAndRepeatSettings.self,forKey: .stepAndRepeat)
    }
}
public enum SideKind: String, Codable, Sendable { case front, back }
public struct SlotReference: Equatable, Sendable {
    public var sheet: Int
    public var side: SideKind
    public var slot: Int
    public init(sheet: Int, side: SideKind, slot: Int) { self.sheet = sheet; self.side = side; self.slot = slot }
}
public struct Slot: Equatable, Sendable {
    public var logicalPageIndex: Int? = nil
    public var artworkOffset = Point(0,0)
    public var bookLeafIndex: Int? = nil
    public var bookPanelIsLeft: Bool? = nil
    public var bookRegion: String? = nil
    public var gangJobID: UUID? = nil
    public var gangBlockID: UUID? = nil
    public var sourcePageNumber: Int?
    public var origin: Point
    public var size: Size
    /// Clockwise degrees. Apply horizontal reflection in source trim coordinates before rotation.
    public var rotation: Int
    public var mirrored: Bool
    public var signature: Int
    public var gridPosition: GridPosition?
    /// Artwork extent on the press sheet, including bleed and shared-cut clipping.
    public var artworkClip: Rect?
    /// Identifies the same physical cut piece on both faces of a repeat sheet.
    public var copyIndex: Int?
    /// Logical item face, independent of PDF page identity and press-face turning.
    public var itemSide: SideKind?
    public init(sourcePageNumber: Int?, origin: Point, size: Size, rotation: Int = 0,
                mirrored: Bool = false, signature: Int = 0, gridPosition: GridPosition? = nil, copyIndex: Int? = nil, artworkClip: Rect? = nil, itemSide: SideKind? = nil) {
        self.sourcePageNumber = sourcePageNumber; self.origin = origin; self.size = size
        self.rotation = rotation; self.mirrored = mirrored; self.signature = signature
        self.gridPosition = gridPosition; self.copyIndex = copyIndex; self.artworkClip = artworkClip; self.itemSide = itemSide
    }
    public var x: Double { origin.x }
    public var y: Double { origin.y }
}
public enum MarkKind: Sendable { case crop, fold, bleed, safeArea, pageLabel, margin, gripper, sharedCut }
public struct Mark: Equatable, Sendable {
    public var kind: MarkKind
    public var start: Point
    public var end: Point
    public var label: String?
    public init(kind: MarkKind, start: Point, end: Point, label: String? = nil) {
        self.kind = kind; self.start = start; self.end = end; self.label = label
    }
}
public struct Side: Equatable, Sendable {
    public var slots: [Slot]
    public var marks: [Mark]
    public init(slots: [Slot] = [], marks: [Mark] = []) { self.slots = slots; self.marks = marks }
}
public struct Sheet: Equatable, Sendable {
    public var alignment: BlockAlignment = .gripper
    public var bookInfo: BookSheetInfo? = nil
    public var gangLayout: GangSheetLayout? = nil
    public var gripperEdge: Edge = .bottom
    /// Back-face viewing convention: reflect X (turn) or Y (tumble / side gripper).
    public var backFlipsX = true
    public var size: Size
    public var front: Side
    public var back: Side
    /// Identical physical press sheets; a run is represented once instead of duplicating its geometry.
    public var repeatCount: Int
    public var repeatLayout: RepeatLayout?
    public var serialPlan: SerialNumberPlan? = nil
    /// Non-exportable diagnostic outline used when layout cannot fit.
    public var diagnosticBounds: Rect? = nil
    public init(size: Size, front: Side, back: Side, repeatCount: Int = 1, repeatLayout: RepeatLayout? = nil) {
        self.size = size; self.front = front; self.back = back
        self.repeatCount = repeatCount; self.repeatLayout = repeatLayout
    }
}
public struct ValidationIssue: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning }
    public enum Code: Sendable {
        case bookSettings, gangLayout, invalidInput, missingBleed, mixedPageSizes, pageCountPadding, exceedsSheet, unsupportedBinding, unsupportedCover, sharedCutBleed, insufficientGutter, serialNumbering
    }
    public var severity: Severity
    public var code: Code
    /// User-facing messages are Turkish.
    public var message: String
    public var slot: SlotReference?
    public var affectedPages: [Int] = []
    public var affectedSlots: [SlotReference] = []
    public var occurrenceCount: Int = 1
    public init(_ severity: Severity, _ code: Code, _ message: String, slot: SlotReference? = nil) {
        self.severity = severity; self.code = code; self.message = message; self.slot = slot
    }
}
public struct ImpositionPlan: Sendable {
    public var sheets: [Sheet]
    public var readingOrder: [Int?] = []
    public var blankPositions: [Int] = []
    public var signatureCount = 0
    public var diagnosticSheets: [Sheet] = []
    public var issues: [ValidationIssue] { didSet { groupedIssues = nil } }
    public var groupedIssues: [ValidationIssue]? = nil
    public var addedBlankPages: Int
    public var signaturePageCount: Int
    public var generatedBleed: GeneratedBleedSettings
    public var totalPressSheets: Int {
        sheets.reduce(0) { total,sheet in
            let sum = total.addingReportingOverflow(sheet.repeatCount)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
    public var canExport: Bool { !issues.contains { $0.severity == .error } }
    public init(sheets: [Sheet] = [], issues: [ValidationIssue] = [], addedBlankPages: Int = 0, signaturePageCount: Int = 0,generatedBleed: GeneratedBleedSettings = GeneratedBleedSettings()) {
        self.sheets = sheets; self.issues = issues; self.addedBlankPages = addedBlankPages
        self.signaturePageCount = signaturePageCount; self.generatedBleed = generatedBleed
    }
}
/// Millimetres; implementations require explicit measured stock inputs.
public protocol CreepCalculating {
    func displacement(sheetIndex: Int, sheetCount: Int, stockCaliper: Double) -> Double
}
/// Millimetres; includes only the explicitly supplied stock and allowances.
public protocol SpineThicknessCalculating {
    func thickness(pageCount: Int, stockCaliper: Double) -> Double
}
