import Foundation

public enum SheetSelection: String, Codable, Sendable, CaseIterable { case fixed, efficient, automatic }
public enum ProductionType: String, Codable, Sendable, CaseIterable { case digital, offset }
public enum AutoLayoutField: String, Codable, Sendable, CaseIterable {
    case sheetSize, orientation, allowRotation, marginLeft, marginRight, marginTop, marginBottom, gripperEdge, gripperWidth, gutter, cropLength, cropOffset, bleed, safeArea, generatedEnabled, generatedMethod, generatedTolerance, generatedColor, columns, rows, exportCrop, exportFold, exportBleed, exportSafeArea, exportPageNumbers, exportSheetInfo, exportFullCut, exportLineWidth, exportColor, exportColorBar, exportTargets, exportTargetSize, exportPatchSize, exportBarSide
    public static func changes(from old: Project,to new: Project) -> Set<AutoLayoutField> {
        var result = Set<AutoLayoutField>()
        if old.sheet.size != new.sheet.size { result.insert(.sheetSize) }
        if old.sheet.orientation != new.sheet.orientation { result.insert(.orientation) }
        if old.stepAndRepeat.allowRotation != new.stepAndRepeat.allowRotation { result.insert(.allowRotation) }
        if old.sheet.margins.left != new.sheet.margins.left { result.insert(.marginLeft) }
        if old.sheet.margins.right != new.sheet.margins.right { result.insert(.marginRight) }
        if old.sheet.margins.top != new.sheet.margins.top { result.insert(.marginTop) }
        if old.sheet.margins.bottom != new.sheet.margins.bottom { result.insert(.marginBottom) }
        if old.sheet.gripperEdge != new.sheet.gripperEdge { result.insert(.gripperEdge) }
        if old.sheet.gripperWidth != new.sheet.gripperWidth { result.insert(.gripperWidth) }
        if old.sheet.gutter != new.sheet.gutter { result.insert(.gutter) }
        if old.settings.cropMarkLength != new.settings.cropMarkLength { result.insert(.cropLength) }
        if old.settings.cropMarkOffset != new.settings.cropMarkOffset { result.insert(.cropOffset) }
        if old.settings.bleed != new.settings.bleed { result.insert(.bleed) }
        if old.settings.safeAreaInset != new.settings.safeAreaInset { result.insert(.safeArea) }
        if old.settings.generatedBleed.enabled != new.settings.generatedBleed.enabled { result.insert(.generatedEnabled) }
        if old.settings.generatedBleed.method != new.settings.generatedBleed.method { result.insert(.generatedMethod) }
        if old.settings.generatedBleed.tolerance != new.settings.generatedBleed.tolerance { result.insert(.generatedTolerance) }
        if old.settings.generatedBleed.color != new.settings.generatedBleed.color { result.insert(.generatedColor) }
        if old.stepAndRepeat.columns != new.stepAndRepeat.columns { result.insert(.columns) }
        if old.stepAndRepeat.rows != new.stepAndRepeat.rows { result.insert(.rows) }
        if old.exportMarks.crop != new.exportMarks.crop { result.insert(.exportCrop) }
        if old.exportMarks.fold != new.exportMarks.fold { result.insert(.exportFold) }
        if old.exportMarks.bleed != new.exportMarks.bleed { result.insert(.exportBleed) }
        if old.exportMarks.safeArea != new.exportMarks.safeArea { result.insert(.exportSafeArea) }
        if old.exportMarks.pageNumbers != new.exportMarks.pageNumbers { result.insert(.exportPageNumbers) }
        if old.exportMarks.sheetInfo != new.exportMarks.sheetInfo { result.insert(.exportSheetInfo) }
        if old.exportMarks.fullCut != new.exportMarks.fullCut { result.insert(.exportFullCut) }
        if old.exportMarks.lineWidth != new.exportMarks.lineWidth { result.insert(.exportLineWidth) }
        if old.exportMarks.color != new.exportMarks.color { result.insert(.exportColor) }
        if old.exportMarks.colorBar != new.exportMarks.colorBar { result.insert(.exportColorBar) }
        if old.exportMarks.registrationTargets != new.exportMarks.registrationTargets { result.insert(.exportTargets) }
        if old.exportMarks.targetSize != new.exportMarks.targetSize { result.insert(.exportTargetSize) }
        if old.exportMarks.patchSize != new.exportMarks.patchSize { result.insert(.exportPatchSize) }
        if old.exportMarks.barSide != new.exportMarks.barSide { result.insert(.exportBarSide) }
        return result
    }
}
public struct AutoLayoutSettings: Equatable, Codable, Sendable {
    public enum Level: String, Codable, Sendable { case full = "L1", reduced = "L2", clipped = "L3", fullSheet = "L4" }
    public var production: ProductionType = .digital
    public var selectionPolicy: SheetSelection? = .automatic
    public var sheetSelection: SheetSelection {
        get { selectionPolicy ?? (manualFields.contains(.sheetSize) ? .fixed : .efficient) }
        set { selectionPolicy = newValue }
    }
    public var manualFields = Set<AutoLayoutField>()
    public var automaticFields = Set<AutoLayoutField>()
    public var level: Level?
    public var summary: String?
    public var clipBleedToSheet = false
    /// Only a matching standard full-sheet job may trim up to 1 mm without scaling.
    public var trimTolerance: Double = 0
    public init() {}
    public static var legacy: AutoLayoutSettings {
        var state = AutoLayoutSettings(); state.manualFields = Set(AutoLayoutField.allCases); state.sheetSelection = .fixed; return state
    }
}
public struct AutoLayoutResult: Sendable {
    public let project: Project
    public let presetName: String
    public let summary: String
    public let plan: ImpositionPlan
}

public enum SmartAutoLayout {
    public static let presets: [SheetPreset] = [.a5,.a4,.a3,.sra3,.cm33x48,.cm35x50,.cm50x70,.cm70x100]
    public static func presetName(for size: Size) -> String {
        presets.first { $0.size == size }?.title ?? "Özel"
    }
    private struct Candidate {
        var project: Project
        var score: Int
        var name: String
        var rotations: Int
    }
    public static func arrange(_ original: Project,resetOverrides: Bool = false) -> AutoLayoutResult {
        var state = original.autoLayout ?? AutoLayoutSettings()
        if resetOverrides {
            if state.sheetSelection == .fixed { state.sheetSelection = .automatic }
            state.manualFields = []; state.automaticFields = []
        }
        guard !original.pages.isEmpty,original.pages.allSatisfy({
            $0.trimSize.width.isFinite && $0.trimSize.height.isFinite &&
            $0.trimSize.width > 0 && $0.trimSize.height > 0 && max($0.trimSize.width,$0.trimSize.height) <= 1_000_000
        }) else { return AutoLayoutResult(project: original,presetName: presetName(for: original.sheet.size),summary: "Otomatik düzen için geçerli PDF ölçüleri gerekli.",plan: ImpositionPlanner.plan(original)) }
        var base = original; base.autoLayout = state
        if resetOverrides { base.stepAndRepeat.arrangement = .adjacent }
        let fixedSheet = state.manualFields.contains(.sheetSize) || state.sheetSelection == .fixed
        let match = original.binding == .stepAndRepeat ? presets.first { paper in
            original.pages.allSatisfy { matches($0.trimSize,paper.size) }
        } : nil
        let levels: [AutoLayoutSettings.Level] = [.full,.reduced,.clipped,.fullSheet]
        func candidates(_ size: Size,_ name: String,_ level: AutoLayoutSettings.Level,_ tolerance: Double = 0) -> [Candidate] {
            let orientations: [Orientation] = state.manualFields.contains(.orientation) ? [original.sheet.orientation] : [.portrait,.landscape]
            return orientations.compactMap { orientation in
                let p = configured(base,size: size,level: level,orientation: orientation,tolerance: tolerance)
                let probe = evaluationProject(p)
                let plan = ImpositionPlanner.plan(probe)
                let expected = probe.binding == .stepAndRepeat ? (probe.pages.count+1)/2 : 1
                guard plan.sheets.count >= expected,!plan.issues.contains(where: { $0.code == .exceedsSheet }) else { return nil }
                let score = plan.sheets.reduce(0) { $0+($1.repeatLayout?.copiesPerSheet ?? $1.front.slots.count) }
                return Candidate(project: p,score: score,name: name,rotations: plan.sheets.reduce(0) { $0+($1.front.slots.first?.rotation ?? 0) })
            }
        }
        func best(_ values: [Candidate]) -> Candidate? {
            values.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                let a = $0.project.sheet.size, b = $1.project.sheet.size
                if a.width*a.height != b.width*b.height { return a.width*a.height < b.width*b.height }
                if $0.rotations != $1.rotations { return $0.rotations < $1.rotations }
                return $0.project.sheet.orientation == .portrait && $1.project.sheet.orientation != .portrait
            }.first
        }
        var chosen: Candidate?
        if fixedSheet {
            for level in levels {
                let tolerance = match.map { matches(original.sheet.size,$0.size) && level == .fullSheet ? 1.0 : 0.0 } ?? 0
                chosen = best(candidates(original.sheet.size,presetName(for: original.sheet.size),level,tolerance))
                if chosen != nil { break }
            }
        } else {
            if state.sheetSelection == .automatic {
                if let match { chosen = best(candidates(match.size,match.title,.fullSheet,1)) }
                if chosen == nil {
                    let paper: SheetPreset = state.production == .digital ? .sra3 : .cm33x48
                    for level in levels {
                        chosen = best(candidates(paper.size,paper.title,level))
                        if chosen != nil { break }
                    }
                }
                if chosen == nil {
                    for paper in presets {
                        for level in levels {
                            chosen = best(candidates(paper.size,paper.title,level))
                            if chosen != nil { break }
                        }
                        if chosen != nil { break }
                    }
                }
            } else {
                for level in levels {
                    chosen = best(presets.flatMap { candidates($0.size,$0.title,level) })
                    if chosen != nil { break }
                }
            }
            if chosen == nil {
                let custom = customSize(base)
                chosen = best(candidates(custom,"Özel",.full))
            }
        }
        guard var chosen else {
            let summary = "Otomatik düzen: elle sabitlenen ölçülerle iş sığmıyor; Doğrulama bölümündeki gereken/kullanılabilir ölçüleri kontrol edin."
            base.autoLayout?.summary = summary
            return AutoLayoutResult(project: base,presetName: presetName(for: base.sheet.size),summary: summary,plan: ImpositionPlanner.plan(base))
        }
        let plan = ImpositionPlanner.plan(chosen.project)
        let item = original.pages[0].trimSize
        let itemName = match?.title ?? String(format: "%.1f×%.1f mm ürün",item.width,item.height)
        let margin = chosen.project.sheet.margins
        let margins = Set([margin.left,margin.right,margin.top,margin.bottom]).count == 1 ? String(format: "%.0f",margin.left) :
            String(format: "%.0f/%.0f/%.0f/%.0f",margin.left,margin.right,margin.top,margin.bottom)
        let fullSheet = chosen.project.autoLayout?.level == .fullSheet && match.map({ matches(chosen.project.sheet.size,$0.size) }) == true && (plan.sheets.first?.repeatLayout?.copiesPerSheet == 1)
        let capacity = plan.sheets.first?.repeatLayout?.copiesPerSheet ?? plan.sheets.first?.front.slots.count ?? 0
        let marks = chosen.project.exportMarks.crop ? "kesim işareti var" : "kesim işareti yok"
        var summary = fullSheet ? "\(itemName) ürün → \(chosen.name) tabaka, tam sayfa. Kenar boşluğu \(margins) mm, \(marks)." :
            "\(itemName) → \(chosen.name), \(capacity) adet/tabaka, marj \(margins) mm, \(marks) (\(chosen.project.autoLayout?.level?.rawValue ?? "—"))."
        if !state.manualFields.isEmpty { summary += " Elle seçilen değerler korundu." }
        if original.pages.count > 2 { summary += " Tüm sayfa çiftlerinin sığması kontrol edildi." }
        chosen.project.autoLayout?.summary = summary
        return AutoLayoutResult(project: chosen.project,presetName: chosen.name,summary: summary,plan: plan)
    }
    private static func matches(_ item: Size,_ paper: Size) -> Bool {
        (abs(item.width-paper.width) <= 1.000001 && abs(item.height-paper.height) <= 1.000001) ||
        (abs(item.width-paper.height) <= 1.000001 && abs(item.height-paper.width) <= 1.000001)
    }
    private static func configured(_ base: Project,size: Size,level: AutoLayoutSettings.Level,orientation: Orientation,tolerance: Double) -> Project {
        var p = base
        var state = p.autoLayout ?? AutoLayoutSettings()
        state.automaticFields = []
        func set<T>(_ field: AutoLayoutField,_ key: WritableKeyPath<Project,T>,_ value: T) {
            guard !state.manualFields.contains(field),field != .sheetSize || state.sheetSelection != .fixed else { return }
            p[keyPath: key] = value; state.automaticFields.insert(field)
        }
        let margin: Double = level == .full ? 10 : level == .reduced ? 5 : level == .clipped ? (state.production == .digital ? 3 : 5) : 0
        set(.sheetSize,\.sheet.size,size)
        set(.orientation,\.sheet.orientation,orientation)
        set(.allowRotation,\.stepAndRepeat.allowRotation,true)
        set(.columns,\.stepAndRepeat.columns,nil)
        set(.rows,\.stepAndRepeat.rows,nil)
        set(.marginLeft,\.sheet.margins.left,margin); set(.marginRight,\.sheet.margins.right,margin)
        set(.marginTop,\.sheet.margins.top,margin); set(.marginBottom,\.sheet.margins.bottom,margin)
        set(.gripperEdge,\.sheet.gripperEdge,.bottom)
        set(.gripperWidth,\.sheet.gripperWidth,state.production == .offset ? 10 : 0)
        set(.bleed,\.settings.bleed,level == .fullSheet ? 0 : 3)
        let marks = (level == .full || level == .reduced) && (!state.manualFields.contains(.exportCrop) || p.exportMarks.crop)
        set(.exportCrop,\.exportMarks.crop,marks)
        set(.cropLength,\.settings.cropMarkLength,marks ? 5 : 0)
        set(.cropOffset,\.settings.cropMarkOffset,marks ? p.settings.bleed+0.5 : 0)
        if p.binding != .stepAndRepeat {
            set(.gutter,\.sheet.gutter,2*p.settings.bleed)
        } else {
            switch p.stepAndRepeat.arrangement {
            case .adjacent: set(.gutter,\.sheet.gutter,0)
            case .spaced: set(.gutter,\.sheet.gutter,2*p.settings.bleed)
            case .custom: break
            case nil: set(.gutter,\.sheet.gutter,p.exportMarks.crop ? 2*p.settings.bleed : 0)
            }
        }
        set(.safeArea,\.settings.safeAreaInset,min(5,(base.pages.map { min($0.trimSize.width,$0.trimSize.height) }.min() ?? 20)/4))
        set(.exportFold,\.exportMarks.fold,false); set(.exportBleed,\.exportMarks.bleed,false)
        set(.exportSafeArea,\.exportMarks.safeArea,false); set(.exportPageNumbers,\.exportMarks.pageNumbers,false)
        set(.exportSheetInfo,\.exportMarks.sheetInfo,false); set(.exportFullCut,\.exportMarks.fullCut,false)
        set(.exportLineWidth,\.exportMarks.lineWidth,0.25); set(.exportColor,\.exportMarks.color,.black)
        set(.exportColorBar,\.exportMarks.colorBar,state.production == .offset)
        set(.exportTargets,\.exportMarks.registrationTargets,state.production == .offset)
        set(.exportTargetSize,\.exportMarks.targetSize,5)
        set(.exportPatchSize,\.exportMarks.patchSize,5)
        set(.exportBarSide,\.exportMarks.barSide,.gripper)
        set(.generatedEnabled,\.settings.generatedBleed.enabled,p.settings.bleed > 0 && p.pages.contains { ($0.availableBleed ?? 0) < p.settings.bleed })
        set(.generatedMethod,\.settings.generatedBleed.method,.automatic)
        set(.generatedTolerance,\.settings.generatedBleed.tolerance,0.02)
        set(.generatedColor,\.settings.generatedBleed.color,.cmyk(0,0,0,0))
        state.level = level; state.clipBleedToSheet = level == .clipped || level == .fullSheet
        state.trimTolerance = level == .fullSheet ? tolerance : 0
        p.autoLayout = state
        return p
    }
    /// Compare geometry once per distinct page-pair size. Quantity, serials and duplicated jobs do not change fit.
    private static func evaluationProject(_ original: Project) -> Project {
        var p = original; p.serialFields = []; p.stepAndRepeat.quantity = 1
        p.stepAndRepeat.waste = nil
        if p.binding == .stepAndRepeat {
            var seen = Set<String>(), pages: [SourcePage] = []
            var layout = PageLayoutSettings(); layout.mode = .duplex
            for job in p.repeatJobs {
                let pair = [job.front,job.back].compactMap { $0 }
                let key = pair.map { "\($0.trimSize.width)/\($0.trimSize.height)" }.joined(separator: ":")
                if seen.insert(key).inserted {
                    pages += pair
                    layout.overrides.append(PageJobOverride(frontPage: job.front.number,layout: job.back == nil ? .simplex : .duplex))
                }
            }
            p.pages = pages; p.stepAndRepeat.pageLayout = layout
        }
        return p
    }
    private static func customSize(_ base: Project) -> Size {
        let p = configured(base,size: base.sheet.size,level: .full,orientation: base.sheet.orientation,tolerance: 0)
        let c = Double(max(1,p.stepAndRepeat.columns ?? (p.settings.turnMethod == .sheetwise ? 1 : 2)))
        let r = Double(max(1,p.stepAndRepeat.rows ?? (p.settings.turnMethod == .sheetwise ? 1 : 2)))
        let spacing = p.sheet.gutter == 0 ? 0 : 2*p.settings.bleed+p.sheet.gutter
        let reserve = max(p.settings.bleed,p.settings.cropMarkLength+p.settings.cropMarkOffset)
        let largestW = p.pages.map(\.trimSize.width).max() ?? 1
        let largestH = p.pages.map(\.trimSize.height).max() ?? 1
        var w = c*largestW+(c-1)*spacing+p.sheet.margins.left+p.sheet.margins.right+2*p.sheet.gripperWidth+2*reserve
        var h = r*largestH+(r-1)*spacing+p.sheet.margins.top+p.sheet.margins.bottom+2*p.sheet.gripperWidth+2*reserve
        if p.binding != .stepAndRepeat { w *= 4; h *= 4 }
        if p.sheet.orientation == .portrait && w > h { h = w }
        if p.sheet.orientation == .landscape && h > w { w = h }
        return Size(ceil(w),ceil(h))
    }
}
