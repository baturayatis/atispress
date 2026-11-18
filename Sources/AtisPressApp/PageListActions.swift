import SwiftUI
import ImpositionCore
import PDFEngine

extension ProjectState {
    func matchesPageMetadata(_ source:PDFSource)->Bool {
        if let items=project.pageItems {
            return items.allSatisfy { item in
                guard let number=item.sourcePage else {return true}
                guard source.pages.indices.contains(number-1) else {return false}
                let page=source.pages[number-1]
                return item.size==page.trimSize && item.availableBleed==page.availableBleed
            }
        }
        return project.pages.allSatisfy {page in
            source.pages.indices.contains(page.number-1) && source.pages[page.number-1].sourcePage==page
        }
    }
}

extension Workspace {
    var pageListItems:[PageListItem] {
        let raw=project.pageItems ?? source?.pages.map{PageListItem(id:$0.number,sourcePage:$0.number,size:$0.trimSize,availableBleed:$0.availableBleed)} ?? []
        guard raw.contains(where:{$0.side==nil}) else {return raw}
        var result=raw
        let jobs=project.repeatJobs
        for job in jobs {
            let pair=UUID()
            if let i=result.firstIndex(where:{$0.id==job.front.number}) {result[i].side=job.back==nil ? .single:.front;result[i].pairID=job.back==nil ? nil:pair}
            if let back=job.back,let i=result.firstIndex(where:{$0.id==back.number}) {result[i].side = .back;result[i].pairID=pair}
        }
        for i in result.indices where result[i].side==nil {result[i].side = .single}
        return result
    }
    func pageListItem(_ id:Int)->PageListItem? {pageListItems.first{$0.id==id}}
    func pageListTitle(_ id:Int)->String {
        guard let item=pageListItem(id),let number=item.sourcePage else {return "Boş"}
        return "Sayfa \(item.localPage ?? number)"+(item.copyNumber>1 ? " (kopya \(item.copyNumber))" : "")
    }
    var canEditPageList:Bool {source != nil && project.binding != .gang && !loading && !preparingSource && !exporting && !autoArranging}
    func pageActionSelection(_ row:Int?)->Set<Int> {
        if let row,!selectedPages.contains(row) {return [row]}
        return selectedPages.intersection(Set(order))
    }
    func pairedPageSelection(_ selection:Set<Int>)->Set<Int> {
        guard project.binding == .stepAndRepeat else {return selection}
        var result=selection
        let items=pageListItems
        let pairs=Set(items.filter{selection.contains($0.id)}.compactMap(\.pairID))
        result.formUnion(items.filter{$0.pairID.map{pairs.contains($0)} == true}.map(\.id))
        return result
    }
    private func nextPageListID(additional:Int)->Int? {
        let previous=project.pageItemNextID.map{$0>0 ? $0-1:0} ?? 0
        let last=max(previous,max(source?.pages.count ?? 0,pageListItems.map(\.id).max() ?? 0))
        let end=last.addingReportingOverflow(additional)
        guard !end.overflow,end.partialValue<Int.max else {error="Sayfa listesine yeni kimlik eklenemedi.";return nil}
        return last+1
    }
    func duplicatePages(_ selection:Set<Int>,copies:Int = 1,wholePairs:Bool = true) {
        guard canEditPageList,(1...99).contains(copies),!selection.isEmpty else {return}
        let selected=(wholePairs ? pairedPageSelection(selection) : selection).intersection(Set(order))
        guard !selected.isEmpty else {return}
        let items=pageListItems,map=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)})
        let oldJobs=project.repeatJobs
        var groups:[[Int]]=[]
        if wholePairs && project.binding == .stepAndRepeat {
            var byPair:[UUID:[PageListItem]]=[:]
            for item in items {if let pair=item.pairID {byPair[pair,default:[]].append(item)}}
            var visited=Set<Int>()
            for id in order where selected.contains(id) && !visited.contains(id) {
                if let pair=map[id]?.pairID {
                    let group=(byPair[pair] ?? []).filter{selected.contains($0.id)}.sorted{$0.side == .front && $1.side != .front}.map(\.id)
                    groups.append(group);visited.formUnion(group)
                }
            }
        }
        let grouped=Set(groups.flatMap{$0})
        groups+=order.filter{selected.contains($0) && !grouped.contains($0)}.map{[$0]}
        var next=project,newItems=items,newOrder=order,newIncluded=included,newSelection=Set<Int>()
        let total=groups.reduce(0){$0+$1.count}.multipliedReportingOverflow(by:copies)
        guard !total.overflow,let firstID=nextPageListID(additional:total.partialValue) else {return}
        var nextID=firstID
        var copyCounts:[Int:Int]=[:]
        for item in items {if let n=item.sourcePage {copyCounts[n]=max(copyCounts[n] ?? 1,item.copyNumber)}}
        guard copyCounts.values.allSatisfy({$0<=Int.max-total.partialValue}) else {error="Kopya numarası sınırına ulaşıldı.";return}
        var pageCopies:[[Int:Int]]=[]
        var layouts=next.stepAndRepeat.pageLayout ?? PageLayoutSettings()
        for group in groups {
            guard let last=order.lastIndex(where:{group.contains($0)}),let anchor=newOrder.firstIndex(of:order[last]) else {continue}
            var insertion=anchor+1
            for _ in 0..<copies {
                var added:[Int]=[],copy:[Int:Int]=[:]
                let newPair=UUID()
                for id in group {
                    guard var item=map[id] else {continue}
                    item.id=nextID;nextID+=1
                    item.pairID=group.count==2 ? newPair:nil
                    if group.count==1 {item.side = .single}
                    if let n=item.sourcePage {copyCounts[n,default:1]+=1;item.copyNumber=copyCounts[n]!}
                    copy[id]=item.id
                    newItems.append(item);added.append(item.id);newSelection.insert(item.id)
                    if included.contains(id) {newIncluded.insert(item.id)}
                }
                pageCopies.append(copy)
                newOrder.insert(contentsOf:added,at:insertion);insertion+=added.count
                if let front=added.first,project.binding == .stepAndRepeat {
                    layouts.overrides.append(PageJobOverride(frontPage:front,layout:added.count==2 ? .duplex : .simplex))
                }
            }
        }
        // A standalone insertion must not split the following existing pair.
        if project.binding == .stepAndRepeat {
            for job in oldJobs {layouts.overrides.removeAll{$0.frontPage==job.front.number};layouts.overrides.append(PageJobOverride(frontPage:job.front.number,layout:job.back==nil ? .simplex : .duplex))}
            next.stepAndRepeat.pageLayout=layouts
        }
        next.pageItems=newItems;next.pageItemNextID=nextID
        commitPageList(next,order:newOrder,included:newIncluded,selection:newSelection,copies:pageCopies)
    }
    func deletePages(_ selection:Set<Int>,wholePairs:Bool = true) {
        guard canEditPageList,!selection.isEmpty else {return}
        let removed=(wholePairs ? pairedPageSelection(selection) : selection).intersection(Set(order))
        guard !removed.isEmpty else {return}
        var next=project
        next.pageItems=pageListItems.filter{!removed.contains($0.id)}
        next.stepAndRepeat.pageLayout?.overrides.removeAll{removed.contains($0.frontPage)}
        if var book=next.book {
            if let n=book.selection.front,removed.contains(n) {book.selection.front=nil}
            if let n=book.selection.back,removed.contains(n) {book.selection.back=nil}
            if let n=book.selection.insideFront,removed.contains(n) {book.selection.insideFront=nil}
            if let n=book.selection.insideBack,removed.contains(n) {book.selection.insideBack=nil}
            book.coverPDFPages.removeAll{removed.contains($0)}
            book.auxiliaryPages.removeAll{removed.contains($0)}
            next.book=book
        }
        commitPageList(next,order:order.filter{!removed.contains($0)},included:included.subtracting(removed),selection:[])
    }
    func insertBlankPages(_ selection:Set<Int> = [],above:Bool = false) {
        guard canEditPageList else {return}
        var items=pageListItems,newOrder=order,newIncluded=included,newSelection=Set<Int>()
        let anchors=order.filter{selection.contains($0)}
        if !selection.isEmpty && anchors.isEmpty {return}
        guard let firstID=nextPageListID(additional:max(1,anchors.count)) else {return}
        var id=firstID
        for anchor in anchors.isEmpty ? [order.last ?? 0] : anchors {
            let size=items.first{$0.id==anchor}?.size ?? project.pages.first?.trimSize ?? source?.pages.first?.trimSize ?? Size(210,297)
            var item=PageListItem(id:id,sourcePage:nil,size:size);item.side = .single
            items.append(item);newIncluded.insert(id);newSelection.insert(id)
            let index=newOrder.firstIndex(of:anchor).map{$0+(above ? 0:1)} ?? newOrder.count
            newOrder.insert(id,at:index);id+=1
        }
        var next=project;next.pageItems=items;next.pageItemNextID=id
        commitPageList(next,order:newOrder,included:newIncluded,selection:newSelection)
    }
    func movePages(_ selection:Set<Int>,toEnd:Bool) {
        guard canEditPageList else {return}
        let moved=order.filter{selection.contains($0)},remaining=order.filter{!selection.contains($0)}
        guard !moved.isEmpty else {return}
        commitPageList(project,order:toEnd ? remaining+moved : moved+remaining,included:included,selection:selection)
    }
    var pageListBookletSummary:String? {
        guard project.isBooklet else {return nil}
        let blanks=Set(pageListItems.filter{$0.sourcePage==nil}.map(\.id))
        let explicit=project.pages.filter{blanks.contains($0.number)}.count
        if planning {return "\(project.pages.count) sayfa · Listede \(explicit) boş · Forma hesaplanıyor…"}
        let padding=plan.addedBlankPages
        return "\(project.pages.count) sayfa · Listede \(explicit) boş · Eklenecek \(padding) boş"+(plan.issues.contains{$0.severity == .error} ? " · Seçili forma ile yerleşim geçersiz" : "")
    }
}

extension Project {
    mutating func retargetPageListSettings(from old:Project,copies:[[Int:Int]]) {
        let retained=pageItems.map{Set($0.map(\.id))}
        let oldJobs=old.repeatJobs,newJobs=repeatJobs
        func jobIndex(_ oldIndex:Int)->Int? {
            guard oldJobs.indices.contains(oldIndex) else {return nil}
            let oldJob=oldJobs[oldIndex]
            return newJobs.firstIndex{$0.front.number==oldJob.front.number}
                ?? newJobs.firstIndex{$0.back?.number==oldJob.front.number || $0.front.number==oldJob.back?.number}
        }
        if binding == .stepAndRepeat {
            serialFields=old.serialFields.compactMap {field in
                guard oldJobs.indices.contains(field.jobIndex) else {return field}
                guard let index=jobIndex(field.jobIndex) else {return nil}
                var field=field;field.jobIndex=index;return field
            }
            for copy in copies {
                for field in old.serialFields where oldJobs.indices.contains(field.jobIndex) {
                    guard let front=copy[oldJobs[field.jobIndex].front.number],let index=newJobs.firstIndex(where:{$0.front.number==front}) else {continue}
                    var clone=field;clone.id=UUID();clone.jobIndex=index;serialFields.append(clone)
                }
            }
        }
        if let cuts = old.internalCutJobs, binding == .stepAndRepeat {
            var updated = cuts.filter { key, _ in key == 0 || newJobs.contains { $0.front.number == key } }
            for (index, job) in oldJobs.enumerated() {
                guard let settings = cuts[job.front.number] else { continue }
                if let next = jobIndex(index), updated[newJobs[next].front.number] == nil {
                    updated[newJobs[next].front.number] = settings
                }
                for copy in copies {
                    if let key = copy[job.front.number], newJobs.contains(where: { $0.front.number == key }) {
                        updated[key] = settings
                    }
                }
            }
            internalCutJobs = updated.isEmpty ? nil : updated
        }
        var original=old;original.migrateScaling()
        if var scaling=original.scaling {
            scaling.overrides=original.scaling!.overrides.flatMap {value -> [ScalingOverride] in
                var value=value
                if let retained {value.pages.removeAll{!retained.contains($0)}}
                guard !value.pages.isEmpty else {return []}
                if value.jobIndex != nil,binding == .stepAndRepeat {
                    return newJobs.enumerated().compactMap {index,job in
                        var part=value
                        part.pages=part.pages.filter{$0==job.front.number || $0==job.back?.number}
                        part.jobIndex=index
                        return part.pages.isEmpty ? nil:part
                    }
                }
                return [value]
            }
            for copy in copies {
                for value in original.scaling!.overrides {
                    var clone=value;clone.pages=value.pages.compactMap{copy[$0]}
                    guard !clone.pages.isEmpty else {continue}
                    if binding == .stepAndRepeat {
                        clone.jobIndex=newJobs.firstIndex{job in clone.pages.contains(job.front.number) || job.back.map{clone.pages.contains($0.number)} == true}
                    }
                    scaling.overrides.append(clone)
                }
            }
            self.scaling=scaling;rescaleJobs=nil
        }
    }
}

extension Project {
    /// Extend an edited list when another source is linked, without reusing an
    /// occurrence ID as a new PDF page number.
    mutating func appendPageListSources(_ pages:[SourcePage]) throws -> [Int:Int] {
        guard var items=pageItems else {return Dictionary(uniqueKeysWithValues:pages.map{($0.number,$0.number)})}
        let last=max(pageItemNextID.map{$0>0 ? $0-1:0} ?? 0,max(items.map(\.id).max() ?? 0,pages.map(\.number).max() ?? 0))
        let end=last.addingReportingOverflow(pages.count)
        guard !end.overflow,end.partialValue<Int.max else {throw ProjectFileError.invalidSelection}
        var id=last+1
        var mapping:[Int:Int]=[:]
        for page in pages {
            items.append(PageListItem(id:id,sourcePage:page.number,size:page.trimSize,availableBleed:page.availableBleed))
            mapping[page.number]=id;id+=1
        }
        pageItems=items;pageItemNextID=id
        return mapping
    }
    func selectedPageList(order:[Int],included:Set<Int>)->[SourcePage] {
        let map=Dictionary(uniqueKeysWithValues:(pageItems ?? []).map{($0.id,$0)})
        return order.filter{included.contains($0)}.compactMap{map[$0]?.planningPage}
    }
    func artworkPageNumber(_ id:Int)->Int? {
        if let items=pageItems {return items.first{$0.id==id}?.sourcePage}
        return id
    }
}

extension Workspace {
    var hasActualPageBacks:Bool {
        if project.binding == .gang {return (project.gang?.jobs ?? []).contains{job in job.back.map{project.artworkPageNumber($0.number) != nil} == true}}
        if project.pageItems == nil {return project.repeatJobs.contains{$0.back != nil}}
        return pageListItems.contains{$0.side == .back && $0.sourcePage != nil && included.contains($0.id)}
    }
    var requiresBacklessConfirmation:Bool {
        (project.binding == .stepAndRepeat || project.binding == .gang) && project.hasPanelItems && project.previouslyHadBacks == true && !hasActualPageBacks
    }
    func pageSideTitle(_ id:Int)->String {
        switch pageListItem(id)?.side {
        case .front:return "Ön"
        case .back:return "Arka"
        case .single:return "Tek yüz"
        case nil:return WorkflowPresentation.pageRole(id,project:project)
        }
    }
    func assignPageSides(_ mode:PageLayout) {
        var next=project,items=pageListItems
        if mode == .simplex {
            for i in items.indices {if items[i].side != .single {items[i].previousSide=items[i].side};items[i].side = .single}
        } else {
            var used=Set<Int>()
            for i in items.indices {
                if let pair=items[i].pairID,items[i].previousSide != nil,items.contains(where:{$0.pairID==pair && $0.id != items[i].id}) {
                    items[i].side=items[i].previousSide;used.insert(items[i].id)
                } else if items[i].side == .front || items[i].side == .back {used.insert(items[i].id)}
            }
            let ids=order.filter{!used.contains($0)}
            var pair=UUID()
            for (offset,id) in ids.enumerated() {
                guard let i=items.firstIndex(where:{$0.id==id}) else {continue}
                if offset%2==0 {pair=UUID()}
                items[i].side=offset%2==0 ? .front:.back;items[i].pairID=pair
            }
        }
        next.pageItems=items
        var layout=next.stepAndRepeat.pageLayout ?? PageLayoutSettings();layout.mode=mode;next.stepAndRepeat.pageLayout=layout
        commitPageList(next,order:order,included:included,selection:selectedPages)
    }
    func setPageSide(_ id:Int,_ side:PageItemSide) {
        guard canEditPageList else {return}
        var items=pageListItems
        guard let index=items.firstIndex(where:{$0.id==id}) else {return}
        if let pair=items[index].pairID {
            for i in items.indices where items[i].pairID==pair {if items[i].side != .single {items[i].previousSide=items[i].side};items[i].side = .single}
        }
        if side != .single {
            items[index].side=side;items[index].pairID=UUID()
            if let position=order.firstIndex(of:id) {
                let other=side == .front ? position+1:position-1
                if order.indices.contains(other),let j=items.firstIndex(where:{$0.id==order[other]}),items[j].side == .single {
                    items[j].side=side == .front ? .back:.front;items[j].pairID=items[index].pairID
                }
            }
        }
        var next=project;next.pageItems=items
        commitPageList(next,order:order,included:included,selection:selectedPages)
    }
    func makePageListDuplex() {
        beginUndoGroup();defer {endUndoGroup()}
        assignPageSides(.duplex)
        for item in pageListItems where item.side == .back {if !included.contains(item.id) {setIncluded(item.id,true)}}
        if requiresBacklessConfirmation {choosePagePDFs(at:order.last)}
    }
}
