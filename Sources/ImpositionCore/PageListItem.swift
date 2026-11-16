import Foundation

/// A project occurrence. Its artwork remains a reference into the source PDF.
public struct PageListItem:Codable,Equatable,Sendable,Identifiable {
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
        var result=plan(input)
        func resolve(_ side:Side)->Side {
            var next=side
            for index in next.slots.indices {
                guard let id=next.slots[index].sourcePageNumber,let item=map[id] else {continue}
                next.slots[index].sourcePageNumber=item.sourcePage
                next.slots[index].insertedBlank=item.sourcePage == nil
            }
            return next
        }
        for index in result.sheets.indices {
            result.sheets[index].front=resolve(result.sheets[index].front)
            result.sheets[index].back=resolve(result.sheets[index].back)
        }
        result.readingOrder=result.readingOrder.map {id in
            guard let id,let item=map[id],item.sourcePage != nil else {return nil}
            return id
        }
        for index in result.diagnosticSheets.indices {
            result.diagnosticSheets[index].front=resolve(result.diagnosticSheets[index].front)
            result.diagnosticSheets[index].back=resolve(result.diagnosticSheets[index].back)
        }
        return result
    }
}
