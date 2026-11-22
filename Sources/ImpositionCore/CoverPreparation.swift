import Foundation

public struct CoverPreparationSettings: Codable, Equatable, Sendable {
    public enum SpineColorMode: String, Codable, Sendable { case automatic, picked, manual }
    public enum Source: String, Codable, CaseIterable, Sendable {
        case firstAndLast, selectedPages, coverFile, separatePDF
    }
    /// Absence preserves projects made with the standalone cover editor.
    public var source: Source?
    public var onlyCover: Bool?
    public var foldMarks: Bool?
    public var front: Int?
    public var back: Int?
    public var spineWidth = 0.0
    public var colorMode = SpineColorMode.automatic
    public var color = BleedColor.cmyk(0,0,0,1)
    public var pickedColor: BleedColor?
    public var spineText: [SpineContent.Position:SpineContent.TextBlock]?
    public var spineLogo: SpineLogo?
    public var spineObjects: [FreeSpineObject]?

    public static let spineObjectLimit = 128
    public static let spineAssetByteLimit = 64*1024*1024

    public var resolvedSpineObjects: [FreeSpineObject] {
        if let spineObjects { return spineObjects }
        var result = SpineContent.Position.allCases.enumerated().compactMap { index,position -> FreeSpineObject? in
            guard let text = spineText?[position], !text.text.isEmpty else { return nil }
            let id = UUID(uuid:(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,UInt8(index+1)))
            return FreeSpineObject(id:id,content:.text(text),legacyPosition:position)
        }
        if let spineLogo { result.append(FreeSpineObject(id:spineLogo.id,content:.logo(spineLogo))) }
        return result
    }

    public mutating func migrateSpineObjects() {
        guard spineText != nil || spineLogo != nil else { return }
        spineObjects = resolvedSpineObjects
        spineText = nil; spineLogo = nil
    }
    public var sheet: SheetSpec?
    public var gap: Double?
    public var bleed: Double?
    public var crop: Bool?
    public var useProjectMachine: Bool?
    public var machine: MachineProfile?
    public var grid = Grid()

    public static let defaultBleed = 3.0

    public func effectiveSheet(for project: Project) -> SheetSpec {
        var result = project.sharedSheet
        result.gutter = gap ?? 0
        return result
    }

    public struct Grid: Codable, Equatable, Sendable {
        public var rotation = MachineProfile.Rotation.automatic
        public var columns: Int?
        public var rows: Int?
        /// Signed displacement from the centered block.
        public var x = 0.0
        public var y = 0.0
        public init() {}
    }
    public init() {}
}

public enum CoverPreparationPlanner {
    public enum Output: String, Sendable, CaseIterable { case spread, sheet }

    public static func plan(_ project: Project, pages: [SourcePage], output: Output, preparedSpread: SourcePage? = nil) -> ImpositionPlan {
        let cover = project.coverPreparation ?? CoverPreparationSettings()
        func error(_ message: String) -> ImpositionPlan {
            ImpositionPlan(issues:[ValidationIssue(.error,.bookSettings,message)])
        }
        if cover.source == .coverFile && pages.count != 2 {
            return error("Sadece kapağı olan iş için iki kapak sayfası gerekir.")
        }
        if cover.source == .separatePDF && pages.isEmpty {
            return error("Ayrı kapak PDF’ini seçin.")
        }
        let front = cover.front.map { number in pages.first { $0.number == number } } ?? pages.first
        let back = cover.back.map { number in pages.first { $0.number == number } } ?? pages.last
        guard let front, let back, cover.source == nil || pages.count == 2 || preparedSpread != nil else { return error("Ön ve arka kapak için geçerli PDF sayfaları seçin.") }
        let height = back.trimSize.height
        guard abs(height-front.trimSize.height) <= 0.001 else {
            return error("Ön ve arka kapak kesim yükseklikleri eşit olmalıdır.")
        }
        guard (0...1000).contains(cover.spineWidth), height.isFinite, height > 0,
              [back.trimSize.width,front.trimSize.width].allSatisfy({ $0.isFinite && $0 > 0 }),
              case .cmyk = cover.color, cover.color.components.allSatisfy({ (0...1).contains($0) }) else {
            return error("Kapak ebatlarını, sırt payını ve CMYK değerlerini kontrol edin.")
        }
        let left = back.trimSize.width
        let right = left+cover.spineWidth
        var size = Size(right+front.trimSize.width,height)
        let bleed = output == .sheet ? cover.bleed ?? (cover.source == nil ? CoverPreparationSettings.defaultBleed : project.settings.bleed) : 0
        guard (0...1000).contains(bleed) else { return error("Taşma 0–1.000 mm arasında olmalıdır.") }
        func panel(_ page: SourcePage?, x: Double, width: Double, label: String) -> Slot {
            let start = x == 0 ? -bleed : x
            let end = x+width+(label == "Ön kapak" ? bleed : 0)
            var slot = Slot(sourcePageNumber:page?.number,origin:Point(x,0),size:page?.trimSize ?? Size(width,height),
                            artworkClip:Rect(x:start,y:-bleed,width:end-start,height:height+2*bleed))
            slot.bookRegion = label
            return slot
        }
        var panels = [panel(back,x:0,width:left,label:"Arka kapak")]
        if cover.spineWidth > 0, preparedSpread == nil {
            var spine = panel(nil,x:left,width:cover.spineWidth,label:"Sırt")
            var content = SpineContent()
            content.mode = .color
            content.color = cover.colorMode == .picked ? cover.pickedColor ?? .rgb(0,0,0) : cover.color
            let objects = cover.resolvedSpineObjects.map { object in
                var result = object
                if case .logo(let logo) = object.content, let percent = logo.spineWidthPercent {
                    result.size = cover.spineWidth*percent/100
                }
                return result
            }
            guard content.isValid(allowRGB:cover.colorMode == .picked),
                  objects.count <= CoverPreparationSettings.spineObjectLimit,
                  Set(objects.map(\.id)).count == objects.count,
                  objects.allSatisfy(\.isValid),
                  objects.reduce(0, { $0+$1.byteCount }) <= CoverPreparationSettings.spineAssetByteLimit else {
                return error("Sırt içeriğinin ölçülerini ve renklerini kontrol edin.")
            }
            content.extendEdges = cover.colorMode == .automatic
            spine.spineArtwork = SpineArtwork(content:content,backPage:back.number,frontPage:front.number,vectorExtension:true,objects:objects,clipLogosToTrim:cover.source != nil)
            panels.append(spine)
        }
        panels.append(panel(front,x:right,width:front.trimSize.width,label:"Ön kapak"))
        if let preparedSpread {
            guard abs(preparedSpread.trimSize.width-size.width) <= 0.01,
                  abs(preparedSpread.trimSize.height-size.height) <= 0.01 else {
                return error(String(format:"Hazır açılım %.3f × %.3f mm. Beklenen %.3f × %.3f mm.",
                                    locale:Locale(identifier:"tr_TR"),preparedSpread.trimSize.width,preparedSpread.trimSize.height,size.width,size.height))
            }
            size = preparedSpread.trimSize
            var slot = panel(preparedSpread,x:0,width:size.width,label:"Hazır açılım")
            slot.artworkClip = Rect(x:-bleed,y:-bleed,width:size.width+2*bleed,height:size.height+2*bleed)
            panels = [slot]
        }
        let guidePositions = cover.source != nil && cover.spineWidth > 0 ? [left,right] : []
        let spineGuides = guidePositions.map { Mark(kind:.fold,start:Point($0,0),end:Point($0,size.height)) }
        if output == .spread {
            var front = Side(slots:panels)
            front.previewMarks = spineGuides
            var sheet = Sheet(size:size,front:front,back:Side())
            sheet.isPreparedCover = cover.source != nil
            var plan = ImpositionPlan(sheets:[sheet])
            if cover.source != nil { plan.tone = project.settings.tone }
            return plan
        }

        var settings = project.settings
        settings.bleed = bleed
        if cover.source == nil { settings.tone = nil }
        settings.turnMethod = .sheetwise
        settings.safeAreaInset = 0
        if cover.source == nil && !(cover.crop ?? project.exportMarks.crop) { settings.cropMarkLength = 0 }
        var input = Project(pages:[SourcePage(number:front.number,trimSize:size,availableBleed:bleed)],
                            sheet:cover.effectiveSheet(for:project),settings:settings,
                            stepAndRepeat:StepAndRepeatSettings(columns:cover.grid.columns,rows:cover.grid.rows,
                                quantity:cover.source == nil ? nil : project.stepAndRepeat.quantity))
        input.machineProfile = project.machineProfile
        var ownership = AutoLayoutSettings.legacy
        ownership.usesExplicitSheet = true
        input.autoLayout = ownership
        input.coverGrid = cover.grid
        input.exportMarks = project.exportMarks
        input.blockAlignment = cover.source == nil ? .center : project.blockAlignment
        let fold = cover.foldMarks == true && cover.spineWidth > 0
        let offset = bleed+max(0.5,settings.cropMarkOffset)
        let length = max(3,settings.cropMarkLength)
        if cover.source != nil {
            let sharedGap = max(0,project.sharedSheet.gutter)
            let markRoom = fold ? max(0.5,settings.cropMarkOffset)+length : 0
            let clearance = max(sharedGap,2*markRoom)
            if input.machineProfile != nil {
                input.sheet.gutter = clearance+2*bleed
            } else {
                input.sheet.gutter = max(bleed > 0 ? 0.000001 : 0,clearance)
            }
            input.stepAndRepeat.waste = project.stepAndRepeat.waste
        }
        if fold {
            let room = max(0,offset+length-bleed)
            input.sheet.margins.left += room
            input.sheet.margins.right += room
            input.sheet.margins.top += room
            input.sheet.margins.bottom += room
        }
        var plan = ImpositionPlanner.plan(input)
        for index in plan.sheets.indices {
            let slots = plan.sheets[index].front.slots
            plan.sheets[index].front.slots = slots.flatMap { whole in
                panels.compactMap { piece in
                    guard var panel = CoverPanelPlacement.place(piece,in:whole,spread:size) else { return nil }
                    panel.copyIndex = whole.copyIndex
                    return panel
                }
            }
            if cover.source != nil {
                plan.sheets[index].isPreparedCover = true
                plan.sheets[index].front.previewMarks = slots.flatMap { whole in
                    spineGuides.map { guide in
                        Mark(kind:guide.kind,
                             start:CoverPanelPlacement.point(guide.start,in:whole,spread:size),
                             end:CoverPanelPlacement.point(guide.end,in:whole,spread:size))
                    }
                }
            }
            if fold {
                for whole in slots {
                    for x in [left,right] {
                        for (a,b) in [(-offset-length,-offset),(size.height+offset,size.height+offset+length)] {
                            plan.sheets[index].front.marks.append(Mark(kind:.spineFold,
                                start:CoverPanelPlacement.point(Point(x,a),in:whole,spread:size),
                                end:CoverPanelPlacement.point(Point(x,b),in:whole,spread:size)))
                        }
                    }
                }
            }
            plan.sheets[index].back = Side()
        }
        if cover.source != nil {
            for i in plan.diagnosticSheets.indices { plan.diagnosticSheets[i].isPreparedCover = true }
        }
        if !settings.generatedBleed.enabled && bleed > 0 {
            let missing = Set((preparedSpread.map { [$0] } ?? [front,back]).filter { ($0.availableBleed ?? 0) < bleed }.map(\.number)).sorted()
            if !missing.isEmpty {
                var issue = ValidationIssue(.warning,.missingBleed,"Kapak yüzlerinde kaynak taşması eksik.")
                issue.affectedPages = missing
                plan.issues.append(issue)
            }
        }
        if cover.source != nil, !plan.canExport,
           plan.issues.contains(where: { $0.code == .exceedsSheet }) {
            let current = input.sheet.size
            let candidates = SheetPreset.allCases.sorted { $0.size.width*$0.size.height < $1.size.width*$1.size.height }
            let next = candidates.first { preset in
                let candidate = preset.size
                guard candidate.width*candidate.height > current.width*current.height else { return false }
                var trial = input
                trial.sheet.size = candidate
                return ImpositionPlanner.plan(trial).canExport
            }
            let dimensions = String(format:"%.3f × %.3f mm",locale:Locale(identifier:"tr_TR"),size.width,size.height)
            let recommendation = next.map { String(format:" En yakın uygun hazır tabaka: %@ (%.3f × %.3f mm).",
                                                   locale:Locale(identifier:"tr_TR"),$0.title,$0.size.width,$0.size.height) } ?? " Uygun daha büyük hazır tabaka bulunamadı."
            plan.issues.append(ValidationIssue(.error,.exceedsSheet,"Kapak açılımı: "+dimensions+"."+recommendation))
        }
        plan.refreshWarningSummary()
        return plan
    }
}

/// Maps cover pieces through the repeat planner's existing placement and clip.
enum CoverPanelPlacement {
    static func point(_ p: Point,in whole: Slot,spread: Size) -> Point {
        // Same clockwise/reflection contract as PDFPreviewDrawing.slotTransform, in pure core.
        func rotated(_ p: Point) -> Point {
            let q = whole.mirrored ? Point(-p.x,p.y) : p
            switch (whole.rotation%360+360)%360 {
            case 90: return Point(q.y,-q.x)
            case 180: return Point(-q.x,-q.y)
            case 270: return Point(-q.y,q.x)
            default: return q
            }
        }
        let corners = [Point(0,0),Point(spread.width,0),Point(0,spread.height),Point(spread.width,spread.height)].map(rotated)
        let q = rotated(p)
        return Point(whole.x+q.x-corners.map(\.x).min()!,whole.y+q.y-corners.map(\.y).min()!)
    }
    static func rect(_ r: Rect,in whole: Slot,spread: Size) -> Rect {
        let points = [r.origin,Point(r.origin.x+r.size.width,r.origin.y),Point(r.origin.x,r.origin.y+r.size.height),Point(r.origin.x+r.size.width,r.origin.y+r.size.height)].map { point($0,in:whole,spread:spread) }
        let x = points.map(\.x),y = points.map(\.y)
        return Rect(x:x.min()!,y:y.min()!,width:x.max()!-x.min()!,height:y.max()!-y.min()!)
    }
    static func place(_ piece: Slot,in whole: Slot,spread: Size) -> Slot? {
        var panel = piece
        let bounds = rect(Rect(x:panel.x,y:panel.y,width:panel.size.width,height:panel.size.height),in:whole,spread:spread)
        panel.origin = bounds.origin; panel.size = bounds.size
        panel.rotation = whole.rotation; panel.mirrored = whole.mirrored
        panel.artworkClip = panel.artworkClip.map { rect($0,in:whole,spread:spread) }
        if let a = panel.artworkClip, let b = whole.artworkClip {
            let x = max(a.origin.x,b.origin.x), y = max(a.origin.y,b.origin.y)
            let width = min(a.origin.x+a.size.width,b.origin.x+b.size.width)-x
            let height = min(a.origin.y+a.size.height,b.origin.y+b.size.height)-y
            guard width > 0,height > 0 else { return nil }
            panel.artworkClip = Rect(x:x,y:y,width:width,height:height)
        }
        panel.itemSide = whole.itemSide
        return panel
    }
}
