import SwiftUI
import ImpositionCore
import PDFEngine

struct PDFInsertSource:Identifiable {
    let id=UUID()
    let url:URL
    let pdf:PDFSource
    var selected:Set<Int>
    var range=""
    var reference:ProjectSource? = nil
}
enum PageInsertionPosition:String,CaseIterable {case above="Seçili sayfanın üstüne",below="Seçili sayfanın altına",start="Başa",end="Sona"}
enum PageInsertionMode {case pairs,fronts,singles,cancel}
enum PageSizeChoice {case preserve,scale,gang,cancel}
struct PDFInsertionDraft:Identifiable {
    let id=UUID()
    var sources:[PDFInsertSource]
    var anchor:Int?
    var position:PageInsertionPosition
    var count:Int {sources.reduce(0){$0+$1.selected.count}}
    var disabledReason:String? {
        if sources.contains(where:{PDFPageRange.parse($0.range,count:$0.pdf.pages.count)==nil}) {return "Sayfa aralığı geçersiz."}
        return count==0 ? "Eklemek için en az bir sayfa seçin.":nil
    }
}
enum PDFPageRange {
    static func parse(_ text:String,count:Int)->Set<Int>? {
        if text.trimmingCharacters(in:.whitespaces).isEmpty {return []}
        var selected=Set<Int>()
        for part in text.split(separator:",",omittingEmptySubsequences:false) {
            let bounds=part.trimmingCharacters(in:.whitespaces).split(separator:"-",omittingEmptySubsequences:false)
            guard (1...2).contains(bounds.count),let start=Int(bounds[0].trimmingCharacters(in:.whitespaces)),start>0,start<=count else {return nil}
            let end=bounds.count==1 ? start:Int(bounds[1].trimmingCharacters(in:.whitespaces)) ?? 0
            guard end>=start,end<=count else {return nil}
            selected.formUnion(start...end)
        }
        return selected
    }
}

extension Workspace {
    func openPagePDF(_ url:URL,password:((URL)->String?)? = nil) async throws -> PDFSource {
        let access=url.startAccessingSecurityScopedResource()
        defer {if access {url.stopAccessingSecurityScopedResource()}}
        do {return try await PDFSource.open(url)}
        catch PDFReadError.locked {
            let value:String?
            if let password {value=password(url)} else {
                let alert=NSAlert();alert.messageText="PDF parolası gerekiyor"
                alert.informativeText=url.lastPathComponent
                let field=NSSecureTextField(frame:NSRect(x:0,y:0,width:300,height:26))
                alert.accessoryView=field;alert.addButton(withTitle:"Aç");alert.addButton(withTitle:"Vazgeç")
                value=alert.runModal() == .alertFirstButtonReturn ? field.stringValue:nil
            }
            guard let value else {throw CancellationError()}
            return try await PDFSource.openWithPassword(url,password:value)
        }
    }
    var canAddPagePDFs:Bool {!loading && !preparingSource && !exporting && !autoArranging && project.binding != .gang}
    func choosePagePDFs(at row:Int? = nil) {
        guard canAddPagePDFs else {return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.pdf];panel.allowsMultipleSelection=true
        panel.title="Sayfalara PDF ekle"
        panel.begin { [weak self] response in
            guard response == .OK,let self else {return}
            self.preparePageInsertion(panel.urls,anchor:row ?? self.order.first(where:{self.selectedPages.contains($0)}))
        }
    }
    func preparePageInsertion(_ urls:[URL],anchor:Int? = nil,password:((URL)->String?)? = nil) {
        guard canAddPagePDFs,!urls.isEmpty else {return}
        loading=true;pdfLoadFailure=nil;error=nil
        Task {
            var activeURL=urls[0],stage="Yer imi oluşturma"
            do {
                var values:[PDFInsertSource]=[]
                for url in urls {
                    activeURL=url;stage="Yer imi oluşturma"
                    let reference=try capturePageSource(url)
                    stage="PDFKit / CGPDFDocument yükleme"
                    let pdf=try await openPagePDF(url,password:password)
                    try checkJobTemplateSize(pdf)
                    values.append(PDFInsertSource(url:url,pdf:pdf,selected:Set(pdf.pages.map(\.number)),reference:reference))
                }
                pdfInsertion=PDFInsertionDraft(sources:values,anchor:anchor,position:anchor==nil ? .end:.above)
            } catch is CancellationError {} catch {
                let failure=recordPDFLoadFailure(error,url:activeURL,stage:stage)
                pdfLoadFailure=failure;self.error=failure.localizedDescription
            }
            loading=false
        }
    }
    func pageInsertionPoint(_ draft:PDFInsertionDraft)->(index:Int,adjusted:Bool) {
        let anchor=draft.anchor.flatMap{order.firstIndex(of:$0)}
        let requested:Int
        switch draft.position {
        case .start:requested=0
        case .end:requested=order.count
        case .above:requested=anchor ?? 0
        case .below:requested=anchor.map{$0+1} ?? order.count
        }
        guard project.binding == .stepAndRepeat,requested>0,requested<order.count else {return (requested,false)}
        let items=pageListItems
        let positions=Dictionary(uniqueKeysWithValues:order.enumerated().map{($0.element,$0.offset)})
        let backs=Dictionary(items.filter{$0.side == .back}.compactMap {item in item.pairID.map{($0,item.id)}},uniquingKeysWith:{$1})
        let intervals=items.filter{$0.side == .front}.compactMap {item -> ClosedRange<Int>? in
            guard let pair=item.pairID,let back=backs[pair],let f=positions[item.id],let b=positions[back] else {return nil}
            return min(f,b)...max(f,b)
        }
        var index=requested
        // Reordered pairs may overlap in the list. Move past every intersected
        // pair so the final insertion point is a boundary for all of them.
        while let interval=intervals.first(where:{index>$0.lowerBound && index<=$0.upperBound}) {
            index=draft.position == .above ? interval.lowerBound:interval.upperBound+1
        }
        return (index,index != requested)
    }
    func insertionUsesDuplex(_ draft:PDFInsertionDraft)->Bool {
        project.binding == .stepAndRepeat && (project.resolvedPageLayout == .duplex || (project.pages.isEmpty && pageLayoutMode != .simplex && draft.count%2==0))
    }
    var insertionTargetSize:Size? {project.rescaledPlanningInput.pages.first?.trimSize}
    func firstDifferentInsertionSize(_ draft:PDFInsertionDraft)->Size? {
        guard let size=insertionTargetSize else {return nil}
        for source in draft.sources {
            if let page=source.pdf.pages.first(where:{source.selected.contains($0.number) && (abs($0.trimSize.width-size.width)>0.01 || abs($0.trimSize.height-size.height)>0.01)}) {return page.trimSize}
        }
        return nil
    }
    func insertionHasDifferentSize(_ draft:PDFInsertionDraft)->Bool {firstDifferentInsertionSize(draft) != nil}
    func insertPagePDFs(_ draft:PDFInsertionDraft,mode:PageInsertionMode,sizeChoice:PageSizeChoice = .preserve) async throws {
        guard mode != .cancel,sizeChoice != .cancel,draft.count>0,canAddPagePDFs else {return}
        guard sizeChoice != .gang || !project.isBooklet else {throw ProjectFileError.invalidSelection}
        preparingSource=true;defer {preparingSource=false}
        let original=source
        let point=pageInsertionPoint(draft),target=insertionTargetSize
        var assets=gangAssets
        if assets.isEmpty,let original {
            let reference=try state.source ?? capturePageSource(original.preparationInput.originalURL)
            assets=[GangAsset(saved:GangSourceReference(id:project.sourcePreparation?.sourceID ?? state.projectID ?? UUID(),reference:reference,pageCount:original.pages.count),source:original)]
        }
        var items=pageListItems
        // Bind legacy occurrences to their physical source before extending it.
        for index in items.indices where items[index].sourcePage != nil && items[index].sourceID==nil {
            let global=items[index].sourcePage!
            var offset=0
            for asset in assets {
                if global>offset && global<=offset+asset.source.pages.count {items[index].sourceID=asset.saved.id;items[index].localPage=global-offset;break}
                offset+=asset.source.pages.count
            }
        }
        var next=project;next.pageItems=items
        let maximum=max(items.map(\.id).max() ?? 0,original?.pages.count ?? 0)
        guard maximum<Int.max else {throw ProjectFileError.invalidSelection}
        var nextID=max(next.pageItemNextID ?? 1,maximum+1)
        let required=draft.count.multipliedReportingOverflow(by:mode == .fronts ? 2:1)
        guard !required.overflow,!nextID.addingReportingOverflow(required.partialValue+1).overflow else {throw ProjectFileError.invalidSelection}
        var added:[PageListItem]=[]
        for entry in draft.sources {
            let existing=assets.firstIndex{PDFSource.sameFile($0.source.originalURL,entry.url)}
            let assetIndex:Int
            if let existing {
                let ref=try entry.reference ?? capturePageSource(entry.url)
                guard ref.fileSize==assets[existing].saved.reference.fileSize,entry.pdf.pages.count==assets[existing].source.pages.count else {throw ProjectFileError.sourceMismatch}
                assetIndex=existing
            }
            else {
                let ref=try entry.reference ?? capturePageSource(entry.url)
                assets.append(GangAsset(saved:GangSourceReference(id:UUID(),reference:ref,pageCount:entry.pdf.pages.count),source:entry.pdf))
                assetIndex=assets.count-1
            }
            let asset=assets[assetIndex],offset=assets.prefix(assetIndex).reduce(0){$0+$1.source.pages.count}
            for page in asset.source.pages where entry.selected.contains(page.number) {
                guard nextID<Int.max-2 else {throw ProjectFileError.invalidSelection}
                var item=PageListItem(id:nextID,sourcePage:offset+page.number,size:page.trimSize,availableBleed:page.availableBleed)
                item.sourceID=asset.saved.id;item.localPage=page.number;item.side = .single
                added.append(item);nextID+=1
            }
        }
        var inserted:[PageListItem]=[]
        if project.binding == .stepAndRepeat && mode == .fronts {
            for var item in added {
                let pair=UUID();item.side = .front;item.pairID=pair;inserted.append(item)
                var blank=PageListItem(id:nextID,sourcePage:nil,size:item.size);nextID+=1
                blank.side = .back;blank.pairID=pair;inserted.append(blank)
            }
        } else {
            for i in added.indices {
                if mode == .pairs && project.binding == .stepAndRepeat {
                    if i%2==0 {added[i].side = .front;added[i].pairID=UUID()}
                    else {added[i].side = .back;added[i].pairID=added[i-1].pairID}
                }
            }
            inserted=added
            if project.binding == .stepAndRepeat,mode == .pairs,added.count%2==1,let front=added.last {
                var blank=PageListItem(id:nextID,sourcePage:nil,size:front.size);nextID+=1
                blank.side = .back;blank.pairID=front.pairID;inserted.append(blank)
            }
        }
        let combined=try await PDFSource.combine(assets.map(\.source))
        let ids=inserted.map(\.id)
        var newOrder=order;newOrder.insert(contentsOf:ids,at:point.index)
        next.pageItems=items+inserted;next.pageItemNextID=nextID
        // Source composition and logical list are committed together for undo.
        if sizeChoice == .scale {beginPDFImportScaling()} else {beginUndoGroup()}
        commitPagePDFInsertion(next,assets:assets,combined:combined,order:newOrder,included:included.union(ids),selection:Set(ids))
        if sizeChoice == .scale,let target {
            setScale(RescaleSettings(target:target),pages:ids,gangID:nil)
            importScalePages=ids
            let row=scalingRows.firstIndex{!Set($0.pages).isDisjoint(with:ids)} ?? 0
            pendingPDFScaleRequest=ScaleWindowRequest(row:row,suggested:RescaleSettings(target:target),importedPages:ids)
        } else {
            if sizeChoice == .gang {setMode(.gang)}
            endUndoGroup()
        }
        pdfInsertion=nil;pdfInsertionIndex=nil
    }
}

extension Workspace {
    func recordPDFLoadFailure(_ error:Error,url:URL,stage:String,details:String="")->PDFLoadFailure {
        let failure:PDFLoadFailure
        if case ProjectFileError.sourceMismatch=error {failure=PDFLoadFailure(.size,url:url,stage:stage,detail:details)}
        else {
            let classified=PDFLoadFailure.classify(error,url:url,stage:stage)
            if error is PDFLoadFailure {failure=classified}
            else {failure=PDFLoadFailure(classified.reason,url:url,stage:classified.stage,detail:classified.detail+(details.isEmpty ? "":"\n"+details))}
        }
        failure.writeLog();return failure
    }
    func copyPDFDiagnostic(_ failure:PDFLoadFailure) {
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(failure.diagnosticText,forType:.string)
    }
}
