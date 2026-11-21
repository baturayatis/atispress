import Foundation

/// A project occurrence. Its artwork remains a reference into the source PDF.
public enum PageItemSide:String,Codable,Sendable {case front,back,single}

public struct PageListItem:Codable,Equatable,Sendable,Identifiable {
    public var sourceID:UUID? = nil
    public var localPage:Int? = nil
    public var previousSide:PageItemSide? = nil
    public var side:PageItemSide? = nil
    public var pairID:UUID? = nil
    public var id:Int
    public var sourcePage:Int?
    public var size:Size
    public var availableBleed:Double?
    public var copyNumber:Int
    public init(id:Int,sourcePage:Int?,size:Size,availableBleed:Double? = nil,copyNumber:Int = 1) {
        self.id=id;self.sourcePage=sourcePage;self.size=size;self.availableBleed=availableBleed;self.copyNumber=copyNumber
    }
    public var planningPage:SourcePage {SourcePage(number:id,trimSize:size,availableBleed:sourcePage == nil ? 10000 : availableBleed)}
}

extension ImpositionPlanner {
    /// Pagination and geometry use occurrence IDs; only artwork references are
    /// resolved afterwards, identically for preview and export.
    static func planPageItems(_ project:Project,items:[PageListItem]) -> ImpositionPlan {
        let map=Dictionary(items.map{($0.id,$0)},uniquingKeysWith:{$1})
        guard map.count==items.count,items.allSatisfy({$0.id>0 && ($0.sourcePage ?? 1)>0}),
              project.pages.allSatisfy({map[$0.number]?.planningPage == $0}) else {
            return ImpositionPlan(issues:[ValidationIssue(.error,.invalidInput,"Sayfa listesi geçersiz.")])
        }
        var input=project;input.pageItems=nil
        let selected=Set(project.pages.map(\.number))
        if project.binding == .stepAndRepeat,items.contains(where:{$0.side != nil}) {
            let jobs=project.repeatJobs
            input.pages=jobs.flatMap{[$0.front]+[$0.back].compactMap{$0}}
            var layout=PageLayoutSettings();layout.mode = .simplex
            layout.overrides=jobs.map{PageJobOverride(frontPage:$0.front.number,layout:$0.back==nil ? .simplex:.duplex)}
            input.stepAndRepeat.pageLayout=layout
        }
        var result=plan(input)
        func resolve(_ side:Side)->Side {
            var next=side
            for index in next.slots.indices {
                if var spine = next.slots[index].spineArtwork {
                    spine.backPage = spine.backPage.flatMap { map[$0]?.sourcePage }
                    spine.frontPage = spine.frontPage.flatMap { map[$0]?.sourcePage }
                    next.slots[index].spineArtwork = spine
                }
                guard let id=next.slots[index].sourcePageNumber,let item=map[id] else {continue}
                next.slots[index].sourcePageNumber=selected.contains(id) ? item.sourcePage:nil
                next.slots[index].insertedBlank=item.sourcePage == nil || !selected.contains(id)
                next.slots[index].sourceID=item.sourceID
                next.slots[index].localSourcePage=item.localPage
            }
            return next
        }
        for index in result.sheets.indices {
            result.sheets[index].front=resolve(result.sheets[index].front)
            result.sheets[index].back=resolve(result.sheets[index].back)
        }
        result.readingOrder=result.readingOrder.map {id in
            guard let id,selected.contains(id),let item=map[id],item.sourcePage != nil else {return nil}
            return id
        }
        for index in result.diagnosticSheets.indices {
            result.diagnosticSheets[index].front=resolve(result.diagnosticSheets[index].front)
            result.diagnosticSheets[index].back=resolve(result.diagnosticSheets[index].back)
        }
        return result
    }
}
