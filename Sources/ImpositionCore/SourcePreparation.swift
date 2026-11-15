import Foundation

public struct SplitCell:Equatable,Codable,Sendable {
    public var product:Int?
    public var side:SideKind
    public init(product:Int?,side:SideKind = .front) { self.product = product; self.side = side }
}
public struct PageSplitSettings:Equatable,Codable,Sendable {
    /// Coordinates in displayed source-trim millimetres, bottom-left origin.
    public var verticalCuts:[Double]
    public var horizontalCuts:[Double]
    /// Reading order: top row first, left to right.
    public var cells:[SplitCell]
    public var cellBleed:Double = 3
    public var explicitTrim:Size?
    public var learnedTrimCenters:[Point]?
    public init(columns:Int = 2,rows:Int = 2,size:Size) {
        verticalCuts = (1..<max(1,columns)).map { Double($0)*size.width/Double(columns) }
        horizontalCuts = (1..<max(1,rows)).map { Double($0)*size.height/Double(rows) }
        cells = (0..<(max(1,columns)*max(1,rows))).map { SplitCell(product:$0/2+1,side:$0%2 == 0 ? .front : .back) }
    }
    public var columns:Int { verticalCuts.count+1 }
    public var rows:Int { horizontalCuts.count+1 }
    public func rectangles(size:Size) -> [Rect] {
        let xs = [0]+verticalCuts+[size.width], ys = [0]+horizontalCuts+[size.height]
        return (0..<rows).reversed().flatMap { row in (0..<columns).map { column in
            Rect(x:xs[column],y:ys[row],width:xs[column+1]-xs[column],height:ys[row+1]-ys[row])
        } }
    }
    public func trim(in cell:Rect) -> Rect {
        let size = explicitTrim ?? Size(cell.size.width-2*cellBleed,cell.size.height-2*cellBleed)
        let center = explicitTrim == nil ? nil:learnedTrimCenters?.first {p in p.x>=cell.origin.x && p.x<=cell.origin.x+cell.size.width && p.y>=cell.origin.y && p.y<=cell.origin.y+cell.size.height}
        return Rect(x:center.map{$0.x-size.width/2} ?? (cell.origin.x+(cell.size.width-size.width)/2),y:center.map{$0.y-size.height/2} ?? (cell.origin.y+(cell.size.height-size.height)/2),width:size.width,height:size.height)
    }
    public func validation(size:Size) -> String? {
        guard (1...12).contains(columns),(1...12).contains(rows),cells.count == columns*rows,
              size.width.isFinite,size.height.isFinite,size.width>0,size.height>0,
              cellBleed.isFinite,cellBleed>=0,cellBleed<=30,
              verticalCuts == verticalCuts.sorted(),horizontalCuts == horizontalCuts.sorted(),
              zip([0]+verticalCuts,verticalCuts+[size.width]).allSatisfy({ $1-$0>1 }),
              zip([0]+horizontalCuts,horizontalCuts+[size.height]).allSatisfy({ $1-$0>1 }) else { return "Kesim çizgileri sıralı ve hücreler en az 1 mm olmalı." }
        if let centers=learnedTrimCenters {guard centers.count==cells.count,centers.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return "Öğrenilmiş kesim merkezleri hücrelerle eşleşmiyor."}}
        let rects = rectangles(size:size)
        if explicitTrim != nil,let centers=learnedTrimCenters {
            guard rects.allSatisfy({cell in centers.filter{p in p.x>=cell.origin.x && p.x<cell.origin.x+cell.size.width && p.y>=cell.origin.y && p.y<cell.origin.y+cell.size.height}.count==1}) else {return "Öğrenilmiş her kesim merkezi ayrı bir hücrede olmalı; kesim çizgilerini ayarlayın."}
        }
        guard rects.allSatisfy({ cell in let t = trim(in:cell); return t.size.width.isFinite && t.size.height.isFinite && t.size.width>0 && t.size.height>0 && t.size.width<=cell.size.width && t.size.height<=cell.size.height && t.origin.x>=cell.origin.x-0.001 && t.origin.y>=cell.origin.y-0.001 && t.origin.x+t.size.width<=cell.origin.x+cell.size.width+0.001 && t.origin.y+t.size.height<=cell.origin.y+cell.size.height+0.001 }) else { return "Kesim ebadı hücrenin içine sığmalı." }
        let products = Set(cells.compactMap(\.product))
        guard !products.isEmpty,products.allSatisfy({ (1...144).contains($0) }) else { return "En az bir ürünün ön yüzünü seçin." }
        guard products.count<=8 else {return "Karışık düzende en fazla 8 ürün desteklenir; fazla hücreleri Boş seçin."}
        for n in products {
            guard cells.filter({ $0.product == n && $0.side == .front }).count == 1,cells.filter({ $0.product == n && $0.side == .back }).count<=1 else { return "Her ürünün bir Ön, en fazla bir Arka hücresi olmalı." }
            let matching = cells.indices.filter { cells[$0].product == n }.map { trim(in:rects[$0]).size }
            guard matching.allSatisfy({ abs($0.width-matching[0].width)<0.01 && abs($0.height-matching[0].height)<0.01 }) else { return "Aynı ürünün Ön ve Arka kesim ebatları eşit olmalı." }
        }
        return nil
    }
    public enum Preset:String,CaseIterable { case row = "Her satır bir ürün: Ön | Arka", column = "Her sütun bir ürün: Ön üstte, Arka altta", simplex = "Hepsi ayrı tek yüzlü ürün" }
    public var matchingPreset:Preset? {
        Preset.allCases.first {preset in var probe=self;probe.assign(preset);return probe.cells==cells}
    }
    public mutating func assign(_ preset:Preset) {
        cells = (0..<(columns*rows)).map { i in
            switch preset {
            case .row: return SplitCell(product:i/columns*((columns+1)/2)+(i%columns)/2+1,side:i%columns%2 == 0 ? .front : .back)
            case .column: return SplitCell(product:(i/columns)/2*columns+i%columns+1,side:(i/columns)%2 == 0 ? .front : .back)
            case .simplex: return SplitCell(product:i+1)
            }
        }
    }
}
public struct SourcePreparationSettings:Equatable,Codable,Sendable {
    public var sourceID:UUID
    public var split:PageSplitSettings?
    public var hiddenGuideGroups:[String] = []
    public var ignoreSplitSuggestion:Bool = false
    public init(sourceID:UUID = UUID()) { self.sourceID = sourceID }
}
