import SwiftUI
import ImpositionCore

struct PageDuplicateRequest:Identifiable {
    let id=UUID()
    let selection:Set<Int>
}
struct PageDuplicateView:View {
    @ObservedObject var model:Workspace
    let request:PageDuplicateRequest
    @State private var copies=1
    @State private var wholePairs=true
    @Environment(\.dismiss) private var dismiss
    private var hasPair:Bool {model.pairedPageSelection(request.selection) != request.selection}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Sayfaları çoğalt").font(.title2.bold())
            HStack {
                Text("Kaç kopya?")
                TextField("1–99",value:$copies,format:.number).textFieldStyle(.roundedBorder).frame(width:72).accessibilityLabel("Kaç kopya, 1–99")
                Stepper("Kopya sayısı",value:$copies,in:1...99).labelsHidden()
                Text("1–99").font(.system(size:12))
            }
            if hasPair {
                Text("Bu sayfa bir Ön/Arka çiftinin parçası. Çift birlikte yeni bir ürün olarak çoğaltılır.")
                Toggle(request.selection.count==1 ? "Sadece bu sayfayı çoğalt":"Sadece seçili sayfaları çoğalt",isOn:Binding(get:{!wholePairs},set:{wholePairs = !$0}))
            }
            HStack {
                Button("Vazgeç") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Çoğalt") {model.duplicatePages(request.selection,copies:copies,wholePairs:wholePairs);dismiss()}.keyboardShortcut(.defaultAction).disabled(!(1...99).contains(copies))
            }
        }.padding(24).frame(width:410)
    }
}
extension Workspace {
    func requestPageDuplicate(_ row:Int? = nil,chooseCount:Bool = false) {
        let selection=pageActionSelection(row)
        guard canEditPageList,!selection.isEmpty else {return}
        if chooseCount || pairedPageSelection(selection) != selection {pageDuplicateRequest=PageDuplicateRequest(selection:selection)}
        else {duplicatePages(selection)}
    }
    func requestPageDelete(_ row:Int? = nil) {
        let selection=pageActionSelection(row)
        guard canEditPageList,!selection.isEmpty else {return}
        let pair=pairedPageSelection(selection)
        if pair != selection {
            let alert=NSAlert()
            alert.messageText="Ön/Arka çifti listeden silinsin mi?"
            alert.informativeText="Seçim çiftin bir yüzünü içeriyor. Yalnız seçili yüz silinirse kalan sayfalar Ön/Arka olarak yeniden eşlenir. Kaynak PDF korunur."
            alert.addButton(withTitle:"Çifti sil")
            alert.addButton(withTitle:"Sadece seçili sayfaları sil")
            alert.addButton(withTitle:"İptal")
            let result=alert.runModal()
            if result == .alertFirstButtonReturn {deletePages(selection)}
            if result == .alertSecondButtonReturn {deletePages(selection,wholePairs:false)}
        } else if selection.count>1 {
            let alert=NSAlert();alert.messageText="\(selection.count) sayfa listeden silinsin mi?"
            alert.informativeText="Kaynak PDF korunur. Bu işlem Geri Al ile geri alınabilir."
            alert.addButton(withTitle:"Listeden sil");alert.addButton(withTitle:"İptal")
            if alert.runModal() == .alertFirstButtonReturn {deletePages(selection)}
        } else {deletePages(selection)}
    }
}
struct PageActionsMenu:View {
    @ObservedObject var model:Workspace
    let row:Int
    private var selection:Set<Int> {model.pageActionSelection(row)}
    var body:some View {
        Button("Çoğalt") {model.requestPageDuplicate(row)}
        Button("Kaç kopya?…") {model.requestPageDuplicate(row,chooseCount:true)}
        Button("Sil") {model.requestPageDelete(row)}.help("Listeden sil · Kaynak PDF korunur")
        Divider()
        Button("Üstüne boş sayfa ekle") {model.insertBlankPages(selection,above:true)}
        Button("Altına boş sayfa ekle") {model.insertBlankPages(selection)}
        Divider()
        Button("Başa taşı") {model.movePages(selection,toEnd:false)}
        Button("Sona taşı") {model.movePages(selection,toEnd:true)}
    }
}
struct PageListRow:View {
    @ObservedObject var model:Workspace
    let id:Int
    @State private var thumbnail:NSImage?
    var body:some View {
        if let item=model.pageListItem(id) {
            HStack(alignment:.top,spacing:8) {
                ZStack {
                    RoundedRectangle(cornerRadius:3).fill(DesignSystem.paper)
                    if let thumbnail {Image(nsImage:thumbnail).resizable().scaledToFit()}
                    if item.sourcePage==nil {RoundedRectangle(cornerRadius:3).stroke(DesignSystem.muted,style:StrokeStyle(lineWidth:1,dash:[4,3]))}
                }.frame(width:36,height:50).accessibilityLabel(item.sourcePage==nil ? "Boş sayfa" : "Sayfa önizlemesi")
                VStack(alignment:.leading,spacing:4) {
                    Text(model.pageListTitle(id)).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                    Text(TRFormat.size(item.size.width,item.size.height)).font(.system(size:12))
                    Text(WorkflowPresentation.pageRole(id,project:model.project)).font(.system(size:12)).foregroundStyle(DesignSystem.muted)
                    Toggle("Baskıya dahil",isOn:Binding(get:{model.included.contains(id)},set:{model.setIncluded(id,$0)}))
                        .toggleStyle(.checkbox).font(.system(size:12)).help("Geçici olarak baskıya dahil et veya çıkar")
                }.frame(maxWidth:.infinity,alignment:.leading)
                Menu {PageActionsMenu(model:model,row:id)} label: {Text("…")}
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(model.pageListTitle(id)+" işlemleri")
            }.opacity(model.included.contains(id) ? 1:0.5)
                .contextMenu {PageActionsMenu(model:model,row:id)}
                .task(id:"\(model.source?.id.uuidString ?? "")-\(item.sourcePage ?? 0)") {
                    guard let number=item.sourcePage else {thumbnail=nil;return}
                    let image=await model.source?.image(page:number,pixels:128)
                    if !Task.isCancelled {thumbnail=image}
                }
        }
    }
}
