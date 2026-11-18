public struct InternalCutMarks: Equatable, Codable, Sendable {
    public struct Direction: Equatable, Codable, Sendable {
        public enum Position: String, Codable, Sendable { case center, custom }
        public var enabled = false
        public var position: Position = .center
        public var offsets: [Double] = []
        public init() {}

        func positions(in length: Double) -> [Double]? {
            guard enabled else { return [] }
            if position == .center { return [length / 2] }
            guard !offsets.isEmpty, offsets.count <= 32,
                  offsets.allSatisfy({ $0.isFinite && $0 > 0 && $0 < length }) else { return nil }
            return Set(offsets).sorted()
        }
    }
    public var horizontal = Direction()
    public var vertical = Direction()
    public init() {}
}

extension ImpositionPlanner {
    static func applyInternalCuts(_ project: Project, to plan: inout ImpositionPlan) {
        let jobs = Dictionary((project.gang?.jobs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !(project.internalCutJobs?.isEmpty ?? true) || jobs.values.contains(where: { $0.internalCuts != nil }) else { return }
        var invalidPages = Set<Int>()
        let length = project.settings.cropMarkLength > 0 ? project.settings.cropMarkLength : 5
        let offset = project.settings.cropMarkOffset
        guard length.isFinite, offset.isFinite, offset >= 0 else { return }

        func addMarks(to side: inout Side, jobKey: Int) {
            for slot in side.slots {
                let options: InternalCutMarks?
                if let id = slot.gangJobID { options = jobs[id]?.internalCuts }
                else { options = project.internalCutJobs?[jobKey] }
                guard let options else { continue }
                let rotated = slot.rotation % 180 != 0
                let width = rotated ? slot.size.height : slot.size.width
                let height = rotated ? slot.size.width : slot.size.height
                let horizontal = options.horizontal.positions(in: height)
                let vertical = options.vertical.positions(in: width)
                if horizontal == nil || vertical == nil, let number = slot.sourcePageNumber { invalidPages.insert(number) }

                // Source trim coordinates, with the same clockwise rotation and
                // pre-rotation reflection as the artwork transform.
                func placed(_ u: Double, _ v: Double) -> Point {
                    let x = slot.mirrored ? width - u : u
                    switch (slot.rotation % 360 + 360) % 360 {
                    case 90: return Point(slot.x + v, slot.y + width - x)
                    case 180: return Point(slot.x + width - x, slot.y + height - v)
                    case 270: return Point(slot.x + height - v, slot.y + x)
                    default: return Point(slot.x + x, slot.y + v)
                    }
                }
                let bounds = slot.productionProtectedBounds
                func appendTicks(_ a: Point, _ b: Point) {
                    let flat = a.y == b.y
                    let fixed = flat ? a.y : a.x
                    let trimLo = flat ? min(a.x, b.x) : min(a.y, b.y)
                    let trimHi = flat ? max(a.x, b.x) : max(a.y, b.y)
                    let protectedLo = flat ? bounds.origin.x : bounds.origin.y
                    let protectedHi = protectedLo + (flat ? bounds.size.width : bounds.size.height)
                    let lower = min(protectedLo, trimLo - offset)
                    let upper = max(protectedHi, trimHi + offset)
                    func point(_ value: Double) -> Point { flat ? Point(value, fixed) : Point(fixed, value) }
                    side.marks.append(Mark(kind: .internalCut, start: point(lower - length), end: point(lower)))
                    side.marks.append(Mark(kind: .internalCut, start: point(upper), end: point(upper + length)))
                }
                for y in horizontal ?? [] { appendTicks(placed(0, y), placed(width, y)) }
                for x in vertical ?? [] { appendTicks(placed(x, 0), placed(x, height)) }
            }
        }

        for index in plan.sheets.indices {
            let key = project.binding == .stepAndRepeat ? plan.sheets[index].repeatLayout?.frontPageNumber ?? 0 : 0
            addMarks(to: &plan.sheets[index].front, jobKey: key)
            addMarks(to: &plan.sheets[index].back, jobKey: key)
        }
        if !invalidPages.isEmpty {
            var issue = ValidationIssue(.error, .invalidInput, "İç kesim konumları kesim ebadının içinde olmalı. Her yön için en fazla 32 konum girin.")
            issue.affectedPages = invalidPages.sorted()
            plan.issues.append(issue)
        }
    }
}
