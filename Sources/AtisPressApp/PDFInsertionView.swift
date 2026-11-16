import SwiftUI
import UniformTypeIdentifiers
import PDFEngine
import ImpositionCore

struct PDFInsertionView:View {
    @ObservedObject var model:Workspace
    @State var draft:PDFInsertionDraft
    @State private var pairs:Bool
    @State private var working=false
    @State private var failure:String?
    @Environment(\.dismiss) private var dismiss
    init(model:Workspace,draft:PDFInsertionDraft) {
        self.model=model;_draft=State(initialValue:draft)
        _pairs=State(initialValue:model.insertionUsesDuplex(draft) && draft.count%2==0)
    }
    private var duplex:Bool {model.insertionUsesDuplex(draft)}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Sayfalara PDF ekle").font(.title2.bold())
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    ForEach(draft.sources.indices,id:\.self) {index in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text(draft.sources[index].url.lastPathComponent).bold()
                                Spacer()
                                Button("↑") {draft.sources.swapAt(index,index-1)}.disabled(index==0).help("PDF'yi yukarı taşı")
                                Button("↓") {draft.sources.swapAt(index,index+1)}.disabled(index==draft.sources.count-1).help("PDF'yi aşağı taşı")
                            }
                            HStack {
                                Button("Tümü") {draft.sources[index].selected=Set(draft.sources[index].pdf.pages.map(\.number));draft.sources[index].range=""}
                                Button("Hiçbiri") {draft.sources[index].selected=[];draft.sources[index].range=""}
                                TextField("Sayfa aralığı: 1-4, 7",text:$draft.sources[index].range)
                                    .onChange(of:draft.sources[index].range) {_,text in
                                        if let selected=PDFPageRange.parse(text,count:draft.sources[index].pdf.pages.count),!text.isEmpty {draft.sources[index].selected=selected}
                                    }
                            }
                            if PDFPageRange.parse(draft.sources[index].range,count:draft.sources[index].pdf.pages.count)==nil {Text("Sayfa aralığı geçersiz.").foregroundStyle(.red)}
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:100))],spacing:12) {
                                ForEach(draft.sources[index].pdf.pages) {page in
                                    VStack {
                                        PDFInsertThumbnail(source:draft.sources[index].pdf,page:page.number)
                                        Toggle("Sayfa \(page.number)",isOn:Binding(get:{draft.sources[index].selected.contains(page.number)},set:{value in
                                            if value {draft.sources[index].selected.insert(page.number)} else {draft.sources[index].selected.remove(page.number)}
                                        }))
                                    }
                                }
                            }
                        }
                    }
                }
            }.frame(height:330)
            Picker("Ekleme konumu",selection:$draft.position) {ForEach(PageInsertionPosition.allCases,id:\.self) {Text($0.rawValue).tag($0)}}
            if model.pageInsertionPoint(draft).adjusted {Text("Ekleme noktası mevcut Ön/Arka çiftinin sınırına taşındı.").foregroundStyle(DesignSystem.warning)}
            if duplex && draft.count%2==0 {Toggle("Ön/arka çifti olarak ekle",isOn:$pairs)}
            Text("\(draft.count) sayfa seçili · Dosyalar yukarıdaki sırayla eklenir.")
            if let failure {Text(failure).foregroundStyle(.red)}
            HStack {
                Button("Vazgeç") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? "Ekleniyor…":"Ekle") {apply()}.keyboardShortcut(.defaultAction)
                    .disabled(working || draft.count==0 || draft.sources.contains{PDFPageRange.parse($0.range,count:$0.pdf.pages.count)==nil})
            }
        }.padding(22).frame(width:690).font(.system(size:13)).disabled(working).interactiveDismissDisabled(working)
            .onAppear {model.pdfInsertionIndex=model.pageInsertionPoint(draft).index}
            .onChange(of:draft.position) {_,_ in model.pdfInsertionIndex=model.pageInsertionPoint(draft).index}
            .onChange(of:draft.count) {_,count in pairs=duplex && count%2==0}
            .onDisappear {model.pdfInsertionIndex=nil}
    }
    private func apply() {
        var mode:PageInsertionMode=pairs ? .pairs:.singles
        if duplex && draft.count%2==1 {
            let alert=NSAlert();alert.messageText="Çift yüzlü işe \(draft.count) sayfa ekliyorsunuz."
            for title in ["Ön yüz olarak ekle, arkaları boş","Ön ve arka olarak eşleştir","Tek yüzlü ayrı iş olarak ekle","Vazgeç"] {alert.addButton(withTitle:title)}
            let result=alert.runModal().rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            mode=[PageInsertionMode.fronts,.pairs,.singles,.cancel][min(3,max(0,result))]
            if mode == .cancel {return}
        }
        var size:PageSizeChoice = .preserve
        if model.insertionHasDifferentSize(draft) {
            let alert=NSAlert()
            let incoming=model.firstDifferentInsertionSize(draft) ?? Size(0,0),existing=model.insertionTargetSize ?? Size(0,0)
            alert.messageText="Bu PDF'in ebadı farklı (\(TRFormat.size(incoming.width,incoming.height)), projede \(TRFormat.size(existing.width,existing.height)))."
            if !model.project.isBooklet {alert.addButton(withTitle:"Ayrı iş olarak ekle (karışık iş)")}
            alert.addButton(withTitle:"Ölçeklendir…");alert.addButton(withTitle:"Vazgeç")
            let index=alert.runModal().rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if model.project.isBooklet {size=index==0 ? .scale:.cancel}
            else {size=index==0 ? .gang:index==1 ? .scale:.cancel}
            if size == .cancel {return}
        }
        working=true
        Task {do {try await model.insertPagePDFs(draft,mode:mode,sizeChoice:size)} catch {failure=error.localizedDescription};working=false}
    }
}
private struct PDFInsertThumbnail:View {
    let source:PDFSource
    let page:Int
    @State private var image:NSImage?
    var body:some View {
        Group {if let image {Image(nsImage:image).resizable().scaledToFit()} else {Rectangle().fill(.white)}}
            .frame(height:100).task {image=await source.image(page:page,pixels:180)}
    }
}
extension Workspace {
    func acceptPagePDFDrop(_ providers:[NSItemProvider],anchor:Int? = nil)->Bool {
        let providers=providers.filter{$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}
        guard canAddPagePDFs,!providers.isEmpty else {return false}
        Task {
            do {
                var urls:[URL]=[]
                for provider in providers {
                    let data:Data=try await withCheckedThrowingContinuation {continuation in
                        provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier) {data,error in
                            if let data {continuation.resume(returning:data)} else {continuation.resume(throwing:error ?? PDFReadError.unreadable)}
                        }
                    }
                    guard let url=URL(dataRepresentation:data,relativeTo:nil),url.isFileURL,url.pathExtension.lowercased()=="pdf" else {throw PDFReadError.unreadable}
                    urls.append(url)
                }
                preparePageInsertion(urls,anchor:anchor)
            } catch {self.error="PDF eklenemedi: "+error.localizedDescription}
        }
        return true
    }
}
