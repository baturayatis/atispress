import CoreGraphics
import ImpositionCore

extension PDFGuideAnalysis {
    /// Proposals for a single displayed artboard. Every boundary and face
    /// remains unassigned until the operator explicitly reviews it.
    public func artworkCandidates(size: Size) -> [ArtworkRegion] {
        let paper = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard !paper.isEmpty else { return [] }
        func rect(_ r: Rect) -> CGRect { CGRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height) }
        func geometry(_ r: CGRect) -> Rect { Rect(x: r.minX, y: r.minY, width: r.width, height: r.height) }
        let frames = learned.filter { $0.page == 1 && paper.insetBy(dx: -0.001, dy: -0.001).contains(rect($0.outer)) }
        guard frames.count <= ArtworkSeparation.maximumRegions else { return [] }
        var frameBoxes: [CGRect] = []
        var candidates: [ArtworkRegion] = []
        for frame in frames {
            let crop = rect(frame.outer).intersection(paper), trim = rect(frame.inner)
            guard !frameBoxes.contains(where: {
                let overlap = $0.intersection(crop)
                return !overlap.isNull && overlap.width > 0.001 && overlap.height > 0.001
            }) else { return [] }
            frameBoxes.append(crop)
            candidates.append(ArtworkRegion(crop: geometry(crop),
                                            bleed: Insets(left: trim.minX - crop.minX, right: crop.maxX - trim.maxX,
                                                          top: crop.maxY - trim.maxY, bottom: trim.minY - crop.minY)))
        }

        // Very busy paths are left for manual selection. Large page-wide
        // fills and content over a known frame cannot establish a new product.
        if regionBounds.count <= 600 {
            var groups: [CGRect] = []
            for bound in regionBounds {
                var box = rect(bound).intersection(paper)
                guard !box.isNull, box.width >= 0.5, box.height >= 0.5,
                      box.width * box.height < 0.8 * paper.width * paper.height,
                      !frameBoxes.contains(where: { $0.intersects(box) }) else { continue }
                while let i = groups.firstIndex(where: { $0.insetBy(dx: -1.5, dy: -1.5).intersects(box) }) {
                    box = box.union(groups.remove(at: i))
                }
                groups.append(box)
            }
            candidates += groups.filter { $0.width >= 5 && $0.height >= 5 }.map { ArtworkRegion(crop: geometry($0)) }
        }
        guard candidates.count >= 2, candidates.count <= ArtworkSeparation.maximumRegions else { return [] }
        return candidates.sorted { a, b in
            if a.crop.origin.y == b.crop.origin.y { return a.crop.origin.x < b.crop.origin.x }
            return a.crop.origin.y > b.crop.origin.y
        }
    }
}
