import Foundation

public struct ArtworkRegion: Equatable, Codable, Sendable, Identifiable {
    public var id = UUID()
    /// Displayed source-trim millimetres, measured from the lower left.
    public var crop: Rect
    public var bleed: Insets
    public var assignment: SplitCell?

    public init(crop: Rect, bleed: Insets = Insets(), assignment: SplitCell? = nil) {
        self.crop = crop
        self.bleed = bleed
        self.assignment = assignment
    }

    public var trim: Rect {
        Rect(x: crop.origin.x + bleed.left, y: crop.origin.y + bleed.bottom,
             width: crop.size.width - bleed.left - bleed.right,
             height: crop.size.height - bleed.top - bleed.bottom)
    }
}

public struct ArtworkSeparation: Equatable, Codable, Sendable {
    public static let maximumRegions = 128
    public var regions: [ArtworkRegion] = []
    public var asTeam = false
    public init() {}

    public func validation(size: Size) -> String? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return "Kaynak sayfanın kesim alanı geçersiz."
        }
        guard !regions.isEmpty, regions.count <= Self.maximumRegions, Set(regions.map(\.id)).count == regions.count else {
            return "1–128 farklı bölge seçin."
        }
        guard regions.allSatisfy({ $0.assignment != nil }) else {
            return "Her bölgeye bir ürün ve yüz atayın veya kullanılmayacak bölgeyi silin."
        }
        let products = Dictionary(grouping: regions.compactMap { region in
            region.assignment?.product.map { ($0, region) }
        }, by: { $0.0 })
        guard !products.isEmpty, products.keys.allSatisfy({ (1...Self.maximumRegions).contains($0) }) else {
            return "En az bir ürünün ön yüzünü atayın."
        }
        if !asTeam && products.count > 8 { return "Sekizden fazla ürün için Tam takım seçin." }
        let selected = regions.filter { $0.assignment?.product != nil }
        for (index, region) in selected.enumerated() {
            let r = region.crop
            guard [r.origin.x, r.origin.y, r.size.width, r.size.height, region.bleed.left, region.bleed.right,
                   region.bleed.top, region.bleed.bottom].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  r.origin.x + r.size.width <= size.width + 0.00001, r.origin.y + r.size.height <= size.height + 0.00001,
                  region.trim.size.width >= 1, region.trim.size.height >= 1 else {
                return "Bölge çalışma alanının içinde olmalı. Kesim eni ve boyu en az 1 mm olmalı."
            }
            for other in selected.prefix(index) {
                let q = other.crop
                if min(r.origin.x + r.size.width, q.origin.x + q.size.width) - max(r.origin.x, q.origin.x) > 0.00001 &&
                   min(r.origin.y + r.size.height, q.origin.y + q.size.height) - max(r.origin.y, q.origin.y) > 0.00001 {
                    return "Kullanılacak bölgelerin taşma dahil sınırları çakışıyor."
                }
            }
        }
        func canonical(_ value: Double) -> Double { (value * 10_000).rounded() }
        for (_, members) in products {
            let fronts = members.filter { $0.1.assignment?.side == .front }
            let backs = members.filter { $0.1.assignment?.side == .back }
            guard fronts.count == 1, backs.count <= 1 else { return "Her ürüne bir ön ve en fazla bir arka yüz atayın." }
            if let back = backs.first?.1.trim.size {
                let front = fronts[0].1.trim.size
                guard canonical(front.width) == canonical(back.width), canonical(front.height) == canonical(back.height) else {
                    return "Aynı ürünün ön ve arka kesim ebatları eşit olmalı."
                }
            }
        }
        return nil
    }
}
