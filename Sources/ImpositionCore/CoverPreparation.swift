import Foundation

public struct CoverPreparationSettings: Codable, Equatable, Sendable {
    public enum SpineColorMode: String, Codable, Sendable { case automatic, manual }
    public var front: Int?
    public var back: Int?
    public var spineWidth = 0.0
    public var colorMode = SpineColorMode.automatic
    public var color = BleedColor.cmyk(0,0,0,1)
    public var sheet: SheetSpec?
    public var bleed: Double?
    public var crop: Bool?
    public var useProjectMachine = true
    public var machine: MachineProfile?
    public var grid = Grid()

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

    public static func plan(_ project: Project, pages: [SourcePage], output: Output) -> ImpositionPlan {
        let cover = project.coverPreparation ?? CoverPreparationSettings()
        func error(_ message: String) -> ImpositionPlan {
            ImpositionPlan(issues:[ValidationIssue(.error,.bookSettings,message)])
        }
        let front = cover.front.map { number in pages.first { $0.number == number } } ?? pages.first
        let back = cover.back.map { number in pages.first { $0.number == number } } ?? pages.last
        guard let front, let back else { return error("Ön ve arka kapak için geçerli PDF sayfaları seçin.") }
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
        let size = Size(right+front.trimSize.width,height)
        let bleed = output == .sheet ? cover.bleed ?? project.settings.bleed : 0
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
        if cover.spineWidth > 0 {
            var spine = panel(nil,x:left,width:cover.spineWidth,label:"Sırt")
            var content = SpineContent()
            content.mode = .color
            content.color = cover.color
            content.extendEdges = cover.colorMode == .automatic
            spine.spineArtwork = SpineArtwork(content:content,backPage:back.number,frontPage:front.number,vectorExtension:true)
            panels.append(spine)
        }
        panels.append(panel(front,x:right,width:front.trimSize.width,label:"Ön kapak"))
        if output == .spread {
            return ImpositionPlan(sheets:[Sheet(size:size,front:Side(slots:panels),back:Side())])
        }

        var settings = project.settings
        settings.bleed = bleed
        settings.tone = nil
        settings.turnMethod = .sheetwise
        settings.safeAreaInset = 0
        if !(cover.crop ?? project.exportMarks.crop) { settings.cropMarkLength = 0 }
        var input = Project(pages:[SourcePage(number:front.number,trimSize:size,availableBleed:bleed)],
                            sheet:cover.sheet ?? project.sheet,settings:settings,
                            stepAndRepeat:StepAndRepeatSettings(columns:cover.grid.columns,rows:cover.grid.rows))
        input.machineProfile = cover.useProjectMachine ? project.machineProfile : cover.machine
        input.coverGrid = cover.grid
        input.exportMarks = project.exportMarks
        input.blockAlignment = .center
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
            plan.sheets[index].back = Side()
        }
        if !settings.generatedBleed.enabled && bleed > 0 {
            let missing = Set([front,back].filter { ($0.availableBleed ?? 0) < bleed }.map(\.number)).sorted()
            if !missing.isEmpty {
                var issue = ValidationIssue(.warning,.missingBleed,"Kapak yüzlerinde kaynak taşması eksik.")
                issue.affectedPages = missing
                plan.issues.append(issue)
            }
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
