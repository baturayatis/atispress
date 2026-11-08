import SwiftUI
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @ObservedObject var model: Workspace
    @State private var dropTarget = false
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 210,idealWidth: 240,maxWidth: 330)
            center.frame(minWidth: 500,maxWidth: .infinity,maxHeight: .infinity)
            InspectorView(model: model).frame(minWidth: 290,idealWidth: 310,maxWidth: 360)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshRecentFiles() }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 10).stroke(.blue,lineWidth: 4).padding(5).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL],isTargeted: $dropTarget,perform: model.acceptDrop)
        .alert("İşlem tamamlanamadı",isPresented: Binding(get: { model.error != nil },set: { if !$0 { model.error = nil } })) {
            Button("Tamam") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .toolbar {
            Button(action: model.openPanel) { Label("PDF Aç",systemImage: "doc.badge.plus") }
            if model.loading { ProgressView().controlSize(.small); Text("PDF okunuyor…") }
            else if let source = model.source { Text(source.displayName).lineLimit(1) }
            Spacer()
            if model.exporting {
                ProgressView().controlSize(.small)
                Text("PDF oluşturuluyor…")
                Button("İptal",action: model.cancelExport)
            }
            Menu {
                Button("Bütün iş — tek PDF…") { model.chooseExport(perSheet: false) }
                Button("Her tabaka — ayrı PDF…") { model.chooseExport(perSheet: true) }
            } label: { Label("PDF Dışa Aktar",systemImage: "square.and.arrow.up") }
                .disabled(!model.canExportNow).help("PDF Dışa Aktar").accessibilityLabel("PDF Dışa Aktar")
            if model.samplingBleed { ProgressView().controlSize(.small); Text("Taşma örnekleniyor…") }
            Button("Otomatik düzenle") { model.autoArrange() }.disabled(model.source == nil || model.loading || model.autoArranging || model.exporting)
            if model.planning { ProgressView().controlSize(.small); Text("Hesaplanıyor…") }
        }
    }
    @ViewBuilder private var sidebar: some View {
        if model.project.binding == .gang { GangSidebarView(model: model) } else { classicSidebar }
    }
    private var classicSidebar: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Kaynak Sayfalar").font(.headline)
                    Spacer()
                    Text("\(model.included.count)/\(model.order.count)").foregroundStyle(.secondary).monospacedDigit()
                }.padding(12)
                HStack {
                    Button("Tümü") { model.includeAll(true) }
                    Button("Hiçbiri") { model.includeAll(false) }
                    Spacer()
                    Button { model.moveSelected(up: true) } label: { Image(systemName: "arrow.up") }.help("Seçili sayfaları yukarı taşı")
                    Button { model.moveSelected(up: false) } label: { Image(systemName: "arrow.down") }.help("Seçili sayfaları aşağı taşı")
                }.buttonStyle(.borderless).disabled(model.source == nil).padding(.horizontal,12).padding(.bottom,8)
                if model.project.isBooklet && model.blankSettings.mode == .manual { BlankPageOrderView(model:model).padding(.horizontal,8) }
                List(selection: $model.selectedPages) {
                    if let source = model.source {
                        ForEach(model.order,id: \.self) { number in
                            PageRow(source: source,number: number,included: Binding(
                                get: { model.included.contains(number) },
                                set: { model.setIncluded(number,$0) }))
                            .tag(number)
                        }.onMove(perform: model.move)
                    }
                }.listStyle(.sidebar)
                Text("✓ Baskıya dahil et · ⌘ ile çoklu seç · sürükleyerek veya ↑↓ ile sırala")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }.frame(minHeight: 250)
            VStack(spacing: 0) {
                HStack { Text(model.project.binding == .stepAndRepeat ? "Tekrarlı İşler" : "Tabakalar / Formalar").font(.headline); Spacer(); Text("\(model.displaySheets.count)") }.padding(12)
                List(selection: $model.sheetIndex) {
                    ForEach(model.displaySheets.indices,id: \.self) { index in
                        let sheet = model.displaySheets[index]
                        let signatures = Set(sheet.front.slots.map(\.signature)).sorted().map { String($0+1) }.joined(separator: ", ")
                        VStack(alignment: .leading,spacing: 4) {
                            if let layout = sheet.repeatLayout {
                                Text("İş \(layout.jobIndex+1) · \(sheet.repeatCount) tabaka").fontWeight(.medium)
                                Picker("İş yüzü",selection: Binding(get: { model.jobPageLayout(frontPage: layout.frontPageNumber) },
                                    set: { model.setJobPageLayout(frontPage: layout.frontPageNumber,mode: $0) })) {
                                    Text("Genel ayar").tag(PageLayout.automatic)
                                    Text("Tek yüz").tag(PageLayout.simplex)
                                    Text("Çift yüz").tag(PageLayout.duplex)
                                }.pickerStyle(.menu)
                                Text("Ön \(layout.frontPageNumber) / Arka \(layout.backPageNumber.map(String.init) ?? "Yok") · \(layout.columns)×\(layout.rows)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let summary = sheet.productionSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                            } else {
                                Text("\(sheet.bookInfo?.label ?? "Tabaka") \(index+1)").fontWeight(.medium)
                                Text("\(sheet.size.width,specifier: "%.0f") × \(sheet.size.height,specifier: "%.0f") mm · \(sheet.bookInfo?.section == .cover ? "Kapak" : "Forma "+signatures)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !sheet.blankPositions.isEmpty { Text("Boş konumlar: "+sheet.blankPositions.map(String.init).joined(separator:", ")).font(.caption).foregroundStyle(.orange) }
                            if let serials = sheet.serialPlan {
                                ForEach(serials.fields) { field in
                                    Text("Seri: \(serials.range(field: field,repetition: index == model.sheetIndex ? model.repetition : 0) ?? "—")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.tag(index)
                        if sheet.serialPlan != nil,index == model.sheetIndex { serialSheetRows(sheet,index: index) }
                    }
                }.listStyle(.sidebar)
            }.frame(minHeight: 130,idealHeight: 230)
        }
    }
    @ViewBuilder
    private func serialSheetRows(_ sheet: Sheet,index: Int) -> some View {
        let first = (model.repetition/100)*100
        if first > 0 { Button("Önceki 100 tabaka") { model.repetition = first-1 } }
        ForEach(first..<(first+min(100,sheet.repeatCount-first)),id: \.self) { repetition in
            Button {
                model.sheetIndex = index; model.repetition = repetition
            } label: {
                VStack(alignment: .leading,spacing: 2) {
                    Text("Tabaka \(repetition+1)"+(model.repetition == repetition ? " · Önizleme" : ""))
                    if let serials = sheet.serialPlan {
                        ForEach(serials.fields) { field in
                            Text(serials.range(field: field,repetition: repetition) ?? "Numara yok").font(.caption)
                        }
                    }
                }
            }.buttonStyle(.plain).padding(.leading,8)
        }
        if sheet.repeatCount-first > 100 { Button("Sonraki 100 tabaka") { model.repetition = first+100 } }
    }
    private var generatedBleedLabel: String? {
        let settings = model.plan.generatedBleed
        guard settings.enabled else { return nil }
        switch settings.method {
        case .automatic: return String(format: "Taşma: Otomatik · tolerans %.1f%%",settings.tolerance*100)
        case .mirror: return "Taşma: Yansıt"
        case .solidColor:
            let space = settings.color.components.count == 4 ? "CMYK" : "RGB"
            return "Taşma: Renk · "+space+" "+settings.color.components.map { String(format: "%.0f",$0*100) }.joined(separator: "/")
        }
    }
    private var center: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Yüz",selection: $model.side) {
                    Text("Ön").tag(SideKind.front)
                    Text("Arka").tag(SideKind.back)
                }.pickerStyle(.segmented).frame(width: 150)
                Spacer()
                Button { model.zoomFactor = 1/1.25; model.zoomAction += 1 } label: { Image(systemName: "minus.magnifyingglass") }.help("Uzaklaştır")
                Button("Sığdır") { model.zoomFactor = 0; model.zoomAction += 1 }
                Button { model.zoomFactor = 1.25; model.zoomAction += 1 } label: { Image(systemName: "plus.magnifyingglass") }.help("Yakınlaştır")
            }.padding(10)
            if let sheet = model.currentSheet,model.side == .back,!sheet.hasContent(on: .back),sheet.diagnosticBounds == nil {
                ContentUnavailableView("Arka yüz yok",systemImage: "doc",description: Text("Bu işin arka yüzünde içerik yok."))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            } else if let sheet = model.currentSheet, let side = model.currentSide {
                PreviewCanvas(sheet: sheet,side: side,sheetIndex: model.sheetIndex,sideKind: model.side,source: model.source,overlays: model.overlays,generatedBleed: model.plan.generatedBleed,
                              highlighted: model.highlightedSlots,zoomAction: model.zoomAction,zoomFactor: model.zoomFactor,
                              repetition: model.repetition,selectedSerial: model.selectedSerialID,
                              selectSerial: model.selectSerial,moveSerial: { model.moveSerialField($0,to: $1) },controlMarks: model.project.exportMarks,moveGangBlock: { model.moveGangBlock($0,to:$1) })
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading,spacing: 3) {
                            Text("\(sheet.repeatLayout == nil ? "Tabaka" : "İş") \(model.sheetIndex+1) · \(model.side == .front ? "Ön" : "Arka") · \(sheet.size.width,specifier: "%.1f") × \(sheet.size.height,specifier: "%.1f") mm")
                            if let layout = sheet.repeatLayout {
                                Text("\(layout.columns)×\(layout.rows) · \(layout.copiesPerSheet) adet/tabaka · \(sheet.repeatCount) tabaka")
                                if let summary = sheet.productionSummary { Text(summary) }
                            }
                            if let info = sheet.bookInfo { Text(info.summary).frame(maxWidth:450,alignment:.leading) }
                            if let label = generatedBleedLabel { Text(label) }
                        }
                            .font(.caption).padding(7).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 6)).padding(10)
                            .allowsHitTesting(false)
                    }
            } else if model.source == nil {
                HomeEmptyStateView(model: model)
            } else {
                ContentUnavailableView("Önizleme oluşturulamadı",systemImage: "exclamationmark.triangle",
                    description: Text("Sayfa seçimini ve aşağıdaki doğrulama mesajlarını kontrol edin."))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            ForEach(model.serialCodeWarnings,id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).padding(.horizontal,10) }
            ForEach(model.previewControlWarnings,id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).padding(.horizontal,10) }
            if !(model.project.isBooklet && model.project.book != nil),let summary = model.project.autoLayout?.summary { Text(summary).font(.caption).padding(.horizontal,10).padding(.vertical,4) }
            Text("Kaydır: izleme dörtgeni / tekerlek · Yakınlaştır: kıstır · Taşı: sürükle · Turuncu: kenar payı / maşa")
                .font(.caption).foregroundStyle(.secondary).padding(6)
            if let summary = model.exportSummary {
                HStack {
                    Text(summary).font(.caption)
                    Spacer()
                    if !model.exportedFiles.isEmpty { Button("Finder’da Göster",action: model.revealExport).font(.caption) }
                }.padding(8)
            }
            Divider()
            VStack(alignment: .leading,spacing: 6) {
                HStack {
                    Text("Doğrulama").font(.headline)
                    Spacer()
                    if let sheet = model.currentSheet, let layout = sheet.repeatLayout {
                        Text("\(layout.copiesPerSheet) adet/tabaka · \(sheet.repeatCount) tabaka · Toplam \(model.plan.totalPressSheets)")
                    } else { Text("Eklenen boş: \(model.plan.addedBlankPages)") }
                    if model.project.isBooklet { Text(model.plan.paginationSummary+" · PDF yüzü: \(model.plan.pdfSideCount(includeBlankBacks:model.project.includeBlankBacks ?? true))").font(.caption) }
                }
                if model.plan.displayIssues.isEmpty {
                    Label(model.source == nil ? "Henüz PDF yüklenmedi" : "Sorun bulunamadı",systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading,spacing: 7) {
                            ForEach(Array(model.plan.displayIssues.enumerated()),id: \.offset) { _,issue in
                                Button { model.reveal(issue) } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                                        Text(issue.message).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        if let ref = issue.slot { Spacer(); Text("T\(ref.sheet+1) · \(ref.side == .front ? "Ön" : "Arka")").foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.font(.caption).padding(12).frame(height: 145)
        }
    }
}

private struct PageRow: View {
    let source: PDFSource
    let number: Int
    @Binding var included: Bool
    @State private var thumbnail: NSImage?
    var body: some View {
        HStack(spacing: 9) {
            Toggle("Dahil",isOn: $included).labelsHidden().toggleStyle(.checkbox)
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(.white)
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: "doc").foregroundStyle(.gray) }
            }.frame(width: 44,height: 62).clipped()
            VStack(alignment: .leading,spacing: 4) {
                Text("Sayfa \(number)")
                let info = source.pages[number-1]
                Text("\(info.trimSize.width,specifier: "%.1f") × \(info.trimSize.height,specifier: "%.1f") mm").font(.caption2)
                Text(info.availableBleed.map { String(format: "Taşma %.1f mm",$0) } ?? "Taşma bilinmiyor")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.opacity(included ? 1 : 0.45)
        .task(id: "\(source.id)-\(number)") {
            let image = await source.image(page: number,pixels: 128)
            if !Task.isCancelled { thumbnail = image }
        }
        .onDisappear { thumbnail = nil }
    }
}
