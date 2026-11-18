import SwiftUI
import ImpositionCore
import PDFEngine

struct PageSourceRecord:Identifiable {
    let id:UUID
    let reference:ProjectSource
    let pageCount:Int
}
extension Workspace {
    var pageSourceRecords:[PageSourceRecord] {
        if !gangAssets.isEmpty {return gangAssets.map{PageSourceRecord(id:$0.saved.id,reference:$0.saved.reference,pageCount:$0.saved.pageCount)}}
        guard let source,let reference=state.source else {return []}
        return [PageSourceRecord(id:project.sourcePreparation?.sourceID ?? state.projectID ?? source.id,reference:reference,pageCount:source.pages.count)]
    }
    func pageSourceName(_ id:Int)->String {
        guard let item=pageListItem(id),item.sourcePage != nil else {return ""}
        if let sourceID=item.sourceID {return pageSourceRecords.first{$0.id==sourceID}?.reference.fileName ?? "Kaynak eksik"}
        return pageSourceRecords.first?.reference.fileName ?? source?.displayName ?? ""
    }
    func currentPageAssets() throws -> [GangAsset] {
        if !gangAssets.isEmpty {return gangAssets}
        guard let source,let record=pageSourceRecords.first else {throw ProjectFileError.invalidSelection}
        return [GangAsset(saved:GangSourceReference(id:record.id,reference:record.reference,pageCount:record.pageCount),source:source)]
    }
    func choosePageSourceRelink(_ id:UUID) {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.pdf];panel.allowsMultipleSelection=false;panel.title="Kaynağı değiştir"
        panel.begin { [weak self] result in
            guard result == .OK,let url=panel.url,let self else {return}
            Task {do {try await self.relinkPageSource(id,url:url)} catch is CancellationError {} catch {self.error=error.localizedDescription}}
        }
    }
    func relinkPageSource(_ id:UUID,url:URL,password:((URL)->String?)? = nil) async throws {
        guard canEditPageList else {return}
        preparingSource=true;defer {preparingSource=false}
        var assets=try currentPageAssets()
        guard let index=assets.firstIndex(where:{$0.saved.id==id}) else {throw ProjectFileError.invalidSelection}
        var pdf=try await openPagePDF(url,password:password)
        if let preparation=project.sourcePreparation,preparation.sourceID==id {pdf=try await pdf.prepared(preparation)}
        let old=assets[index]
        let offset=assets.prefix(index).reduce(0){$0+$1.source.pages.count}
        var items=pageListItems
        for i in items.indices where items[i].sourceID==id || (items[i].sourceID==nil && items[i].sourcePage.map{$0>offset && $0<=offset+old.source.pages.count} == true) {
            let local=items[i].localPage ?? (items[i].sourcePage!-offset)
            guard pdf.pages.indices.contains(local-1),pdf.pages[local-1].trimSize==items[i].size else {throw ProjectFileError.sourceMismatch}
            items[i].sourceID=id;items[i].localPage=local;items[i].availableBleed=pdf.pages[local-1].availableBleed
        }
        assets[index]=GangAsset(saved:GangSourceReference(id:id,reference:try capturePageSource(url),pageCount:pdf.pages.count),source:pdf)
        let combined=try await PDFSource.combine(assets.map(\.source))
        items=resolveSourceOffsets(items,assets:assets)
        var next=project;next.pageItems=items
        commitPagePDFInsertion(next,assets:assets,combined:combined,order:order,included:included,selection:selectedPages)
    }
    func resolveSourceOffsets(_ values:[PageListItem],assets:[GangAsset])->[PageListItem] {
        values.map {value in
            var item=value
            if let id=item.sourceID,let local=item.localPage,let index=assets.firstIndex(where:{$0.saved.id==id}) {
                item.sourcePage=assets.prefix(index).reduce(0){$0+$1.source.pages.count}+local
            }
            return item
        }
    }
    func requestRemovePageSource(_ id:UUID) {
        let alert=NSAlert();alert.messageText="Kaynak ve sayfaları kaldırılsın mı?"
        alert.informativeText="Kaynak PDF diskte korunur. Sayfaları tutmak için kaynağı başka bir PDF'ye bağlayabilirsiniz."+(pageSourceRecords.count==1 ? " Son kaynak kaldırılınca boş satırlar da temizlenir.":"")
        alert.addButton(withTitle:"Sayfalarıyla kaldır");alert.addButton(withTitle:"Sayfaları tut, kaynağı değiştir…");alert.addButton(withTitle:"Vazgeç")
        let result=alert.runModal()
        if result == .alertSecondButtonReturn {choosePageSourceRelink(id)}
        if result == .alertFirstButtonReturn {Task {do {try await removePageSource(id)} catch {self.error=error.localizedDescription}}}
    }
    func removePageSource(_ id:UUID) async throws {
        guard canEditPageList else {return}
        preparingSource=true;defer {preparingSource=false}
        var assets=try currentPageAssets()
        guard let index=assets.firstIndex(where:{$0.saved.id==id}) else {throw ProjectFileError.invalidSelection}
        let start=assets.prefix(index).reduce(0){$0+$1.source.pages.count},end=start+assets[index].source.pages.count
        var items=pageListItems.filter {item in
            if let sourceID=item.sourceID {return sourceID != id}
            return !(item.sourcePage.map{$0>start && $0<=end} ?? false)
        }
        assets.remove(at:index)
        if assets.isEmpty {clearPageSources();return}
        // Bind any remaining legacy source references before offsets change.
        for i in items.indices where items[i].sourcePage != nil && items[i].sourceID==nil {
            let global=items[i].sourcePage!
            var offset=0
            for asset in try currentPageAssets() {
                if global>offset && global<=offset+asset.source.pages.count {items[i].sourceID=asset.saved.id;items[i].localPage=global-offset;break}
                offset+=asset.source.pages.count
            }
        }
        items=resolveSourceOffsets(items,assets:assets)
        let ids=Set(items.map(\.id)),combined=try await PDFSource.combine(assets.map(\.source))
        var next=project;next.pageItems=items
        commitPagePDFInsertion(next,assets:assets,combined:combined,order:order.filter{ids.contains($0)},included:included.intersection(ids),selection:[])
    }
}
struct PageSourcesPopover:View {
    @ObservedObject var model:Workspace
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Kaynaklar").font(.headline)
            ForEach(model.pageSourceRecords) {source in
                VStack(alignment:.leading,spacing:6) {
                    Text("\(source.reference.fileName) · \(source.pageCount) sayfa").bold()
                    Text(source.reference.path).font(.system(size:12)).textSelection(.enabled)
                    HStack {Button("Değiştir…") {model.choosePageSourceRelink(source.id)};Button("Kaldır") {model.requestRemovePageSource(source.id)}}
                }
            }
        }.padding(16).frame(width:430).disabled(!model.canEditPageList)
    }
}
