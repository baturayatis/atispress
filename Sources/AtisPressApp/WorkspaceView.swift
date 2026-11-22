import SwiftUI
import PDFEngine
import ImpositionCore
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @ObservedObject var model: Workspace
    @ObservedObject var prices:PricingStore
    @State private var dropTarget = false
    @State private var pageHelp = false
    @State private var layers = false
    @State private var lineLegend = false
    @State private var pageSources = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                ContextBar(model:model)
                Divider()
                WorkspaceSplitView(settings: model.ui, windowWidth: geometry.size.width) {
                    sidebar
                } preview: {
                    if model.ui.activePanel == .coverPreparation, model.hasCoverArtworkContext,
                       model.project.coverPreparation != nil || !(model.project.isBooklet || model.project.isLeafBinding) {
                        CoverPreparationPreview(model:model)
                    }
                    else { center }
                } tools: {
                    InspectorDock(model: model, prices: prices)
                }.frame(height:max(0,geometry.size.height-57))
            }
        }
        .background(DesignSystem.workspace)
        .onChange(of:model.selectedPages) {_,_ in model.selectedSerialID=nil}
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshRecentFiles() }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 10).stroke(DesignSystem.teal,lineWidth: 4).padding(5).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL],isTargeted: $dropTarget,perform: model.acceptDrop)
        .sheet(isPresented: $model.showingTeamImportChoice) {
            TeamPDFImportDialog(model: model)
                .interactiveDismissDisabled()
        }
        .alert("İşlem tamamlanamadı",isPresented: Binding(get: { model.error != nil },set: { if !$0 { model.error = nil } })) {
            Button("Tamam") { model.error = nil; model.pdfLoadFailure=nil }
            if let failure=model.pdfLoadFailure {Button("Tanı bilgisini kopyala") {model.copyPDFDiagnostic(failure)}}
        } message: { Text(TRFormat.presentation(model.error ?? "")) }
        .sheet(item:$model.pdfInsertion,onDismiss:{model.showPendingPDFScaleWindow()}) {PDFInsertionView(model:model,draft:$0).id($0.id)}
        .sheet(item:$model.pageDuplicateRequest) {PageDuplicateView(model:model,request:$0)}
        .sheet(isPresented: $model.showingArtworkSeparation) { if let input = model.preparationInput { ArtworkSeparationView(model: model, input: input) } }
        .sheet(isPresented:$model.showingPageSplit) { if let input=model.preparationInput {PageSplitView(model:model,input:input)} }
        .sheet(isPresented:$model.showingSourceGuides,onDismiss:{if model.showSplitAfterGuides {model.showSplitAfterGuides=false;model.showingPageSplit=model.canSplitSource}}) { if let input=model.preparationInput {SourceGuidesView(model:model,input:input)} }
        .sheet(isPresented:$model.preparingExport) { ExportPreparationView(model:model) }
        .sheet(item:$model.scaleWindow,onDismiss:{model.finishPDFImportScaling(accepted:false)}) { ScaleWindowView(model:model,request:$0) }
        .toolbar {
            Button(action:model.choosePDF) { HStack { Image(systemName:"doc.badge.plus"); Text("PDF Seç") } }.help("PDF seç · ⌘O")
            JobTemplateMenu(model: model)
            Spacer()
            Button("Otomatik düzenle") { model.requestAutomaticLayout() }.disabled(model.source == nil || model.loading || model.autoArranging || model.exporting)
            Button { model.preparingExport = true } label: {
                HStack(spacing:DesignSystem.Space.sm) { Image(systemName:"square.and.arrow.up"); Text("PDF’i Hazırla").fontWeight(.semibold) }.padding(.horizontal,DesignSystem.Space.md).padding(.vertical,DesignSystem.Space.xs)
            }.buttonStyle(.borderedProminent).tint(DesignSystem.action).controlSize(.large).disabled(!model.canExportNow).accessibilityLabel("PDF’i Hazırla").help("Çıktı seçeneklerini kontrol edip baskı PDF’sini hazırlayın · ⌘E")
            if model.exporting { ProgressView().controlSize(.small); Button("İptal",action:model.cancelExport) }
        }.tint(DesignSystem.teal).disabled(model.preparingSource)
    }
    @ViewBuilder private var sidebar: some View {
        if model.project.binding == .gang { GangSidebarView(model: model) } else { classicSidebar.disabled(model.preparingSource) }
    }
    private var classicSidebar: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Sayfalar").font(.headline)
                    Spacer()
                    Text("\(model.included.count)/\(model.order.count)").foregroundStyle(DesignSystem.muted).monospacedDigit()
                }.padding(12)
                HStack {
                    Button("Tümü") { model.includeAll(true) }
                    Button("Hiçbiri") { model.includeAll(false) }
                    Spacer()
                    Button { model.moveSelected(up: true) } label: { Image(systemName: "arrow.up") }.help("Seçili sayfaları yukarı taşı").accessibilityLabel("Seçili sayfaları yukarı taşı")
                    Button { model.moveSelected(up: false) } label: { Image(systemName: "arrow.down") }.help("Seçili sayfaları aşağı taşı").accessibilityLabel("Seçili sayfaları aşağı taşı")
                }.buttonStyle(.borderless).disabled(model.source == nil).padding(.horizontal,12).padding(.bottom,8)
                if model.project.isBooklet && model.blankSettings.mode == .manual { BlankPageOrderView(model:model).padding(.horizontal,8) }
                HStack(spacing:8) {
                    Button("PDF ekle…") {model.choosePagePDFs()}.disabled(!model.canAddPagePDFs)
                    Button("Kaynaklar") {pageSources.toggle()}.popover(isPresented:$pageSources) {PageSourcesPopover(model:model)}
                }.buttonStyle(.borderless).font(.system(size:12)).padding(.horizontal,8).padding(.bottom,8)
                HStack(spacing:8) {
                    Button("+ Boş sayfa") {model.insertBlankPages(model.selectedPages)}
                    Button("Çoğalt") {model.requestPageDuplicate()}.help("Seçili sayfaları çoğalt · ⌘D").keyboardShortcut("d").disabled(model.selectedPages.isEmpty)
                    Button("Sil") {model.requestPageDelete()}.help("Listeden sil · ⌫ · Geri alınabilir").disabled(model.selectedPages.isEmpty)
                }.buttonStyle(.borderless).font(.system(size:12)).padding(.horizontal,8).padding(.bottom,8).disabled(!model.canEditPageList)
                if let summary=model.pageListBookletSummary {
                    Text(summary).font(.system(size:12)).foregroundStyle(model.plan.addedBlankPages>0 ? DesignSystem.warning:DesignSystem.muted).padding(.horizontal,8)
                }
                List(selection: $model.selectedPages) {
                    ForEach(model.order,id:\.self) {id in
                        PageListRow(model:model,id:id).tag(id)
                            .onDrop(of:[UTType.fileURL],isTargeted:nil) {model.acceptPagePDFDrop($0,anchor:id)}
                            .overlay(alignment:.top) {if model.pdfInsertionIndex==model.order.firstIndex(of:id) {Rectangle().fill(DesignSystem.teal).frame(height:3)}}
                    }
                        .onMove(perform:model.move)
                }.listStyle(.sidebar).onDeleteCommand {model.requestPageDelete()}
                    .onDrop(of:[UTType.fileURL],isTargeted:nil) {model.acceptPagePDFDrop($0)}
                    .overlay(alignment:.bottom) {if model.pdfInsertionIndex==model.order.count {Rectangle().fill(DesignSystem.teal).frame(height:3)}}
                Button { pageHelp.toggle() } label: { Image(systemName:"questionmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Sayfa seçimi yardımı").popover(isPresented:$pageHelp) { Text("Baskıya dahil et · ⌘ ve ⇧ ile çoklu seç · sürükleyerek veya ↑↓ ile sırala").padding().frame(width:260) }
                    .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1).padding(8)
            }.frame(minHeight: 250)
            VStack(spacing: 0) {
                HStack { Text("Tabakalar").font(.headline); Spacer(); Text("\(model.displaySheets.count)") }.padding(12)
                List(selection: Binding(get:{ model.sheetIndex },set:model.selectPreviewSheet)) {
                    ForEach(model.displaySheets.indices,id: \.self) { index in
                        let sheet = model.displaySheets[index]
                        let signatures = Set(sheet.front.slots.map(\.signature)).sorted().map { String($0+1) }.joined(separator: ", ")
                        VStack(alignment: .leading,spacing: 4) {
                            if let layout = sheet.repeatLayout {
                                Text(sheet.isPreparedCover ? "Kapak · Tabakada \(layout.copiesPerSheet) açılım" :
                                     "Tabaka \(index+1) · \(layout.copiesPerSheet) adet").fontWeight(.semibold)
                                Text("\(sheet.hasContent(on:.back) ? "ön ve arka" : "tek yüz") · \(layout.columns)×\(layout.rows)").font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                            } else {
                                Text(model.coverSheetTitle(at:index) ?? "\(sheet.leafInfo == nil ? (sheet.bookInfo?.label ?? "Tabaka") : "Yaprak tabakası") \(index+1)").fontWeight(.medium)
                                if let leaf = sheet.leafInfo { Text(TRFormat.presentation(leaf.summary)).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1) }
                                else {
                                    Text("\(TRFormat.dimension(sheet.size.width)) × \(TRFormat.dimension(sheet.size.height)) mm · \(sheet.bookInfo?.section == .cover ? "Kapak" : "Forma "+signatures)")
                                        .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                                }
                            }
                            if !model.scalingStatus.isEmpty { Text(model.scalingStatus).font(.system(size:12)).foregroundStyle(DesignSystem.muted) }
                            if !sheet.blankPositions.isEmpty { Text("Boş konumlar: "+sheet.blankPositions.map(String.init).joined(separator:", ")).font(.system(size:12)).foregroundStyle(DesignSystem.warning) }
                            if let serials = sheet.serialPlan {
                                ForEach(serials.fields) { field in
                                    Text("Seri: \(serials.range(field: field,repetition: index == model.sheetIndex ? model.repetition : 0) ?? "—")")
                                        .font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
                                }
                            }
                        }.tag(index).padding(.vertical,DesignSystem.Space.xs)
                            .listRowBackground(model.sheetIndex == index ? DesignSystem.selected.opacity(0.12) : DesignSystem.clear)
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
                            Text(serials.range(field: field,repetition: repetition) ?? "Numara yok").font(.system(size:12))
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
        case .automatic: return "Taşma: Otomatik · tolerans \(TRFormat.dimension(settings.tolerance*100))%"
        case .mirror: return "Taşma: Yansıt"
        case .solidColor:
            let space = settings.color.components.count == 4 ? "CMYK" : "RGB"
            return "Taşma: Renk · "+space+" "+settings.color.components.map { TRFormat.dimension($0*100) }.joined(separator: "/")
        }
    }
    private var center: some View {
        VStack(spacing: 0) {
            VStack(spacing:8) {
                HStack {
                    Text("Görünüm:").font(.system(size:12))
                    PreviewScopePicker(model:model).labelsHidden()
                    Spacer(minLength:4)
                    Picker("Yüz",selection: $model.side) {
                        Text("Ön").tag(SideKind.front)
                        Text("Arka").tag(SideKind.back)
                    }.pickerStyle(.segmented).frame(width:150)
                }
                HStack {
                    Button { layers.toggle() } label: { HStack(spacing:4) { Text("Katmanlar"); if model.hasPreviewGuides { Circle().fill(DesignSystem.teal).frame(width:5,height:5) } } }.fixedSize().popover(isPresented:$layers) { PreviewLayersView(model:model) }
                    Button("Çizgiler") { lineLegend.toggle() }.fixedSize().popover(isPresented:$lineLegend) { PreviewLineLegendView(model:model) }
                    Spacer()
                    Text(model.zoomStateLabel).font(.system(size:12)).foregroundStyle(DesignSystem.muted).accessibilityLabel(model.zoomStateLabel)
                    Button { model.zoomFactor = 1/1.25; model.zoomAction += 1 } label: { Image(systemName:"minus.magnifyingglass") }.help("Uzaklaştır").accessibilityLabel("Uzaklaştır")
                    Button("Sığdır") { model.zoomFactor = 0; model.zoomAction += 1 }
                    Button { model.zoomFactor = 1.25; model.zoomAction += 1 } label: { Image(systemName:"plus.magnifyingglass") }.help("Yakınlaştır").accessibilityLabel("Yakınlaştır")
                }
                HStack {
                    if !model.showsAllSides,!model.displaySheets.isEmpty {
                        Button { model.movePreviewSheet(-1) } label: { Image(systemName:"chevron.left") }.accessibilityLabel("Önceki tabaka")
                        Text(model.previewSheetPosition).font(.system(size:12)).monospacedDigit()
                        Button { model.movePreviewSheet(1) } label: { Image(systemName:"chevron.right") }.accessibilityLabel("Sonraki tabaka")
                    }
                    Spacer()
                }
            }.padding(10)
            if model.requiresBacklessConfirmation {
                VStack(alignment:.leading,spacing:8) {
                    Text("Bu iş tek yüze çevrildi: arka yüz baskıya girmeyecek.")
                    HStack {Button("Geri al") {model.undoEdit()}.disabled(!model.canUndo);Button("Çift yüz yap") {model.makePageListDuplex()}}
                }.font(.system(size:13)).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(DesignSystem.warningSurface)
            }
            if model.showsAllSides, !model.displaySheets.isEmpty {
                AllSheetsPreview(model:model)
            } else if let sheet = model.currentSheet,model.side == .back,!model.showsBackInPreview(sheet),sheet.diagnosticBounds == nil {
                ContentUnavailableView("Arka yüz yok",systemImage: "doc",description: Text("Bu işin arka yüzünde içerik yok."))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            } else if let sheet = model.currentSheet, let side = model.currentSide {
                PreviewCanvas(sheet: sheet,side: side,sheetIndex: model.sheetIndex,sideKind: model.side,source: model.source,overlays: model.overlays,printedInfo:model.sheetInfoText(sheet:sheet,number:model.plan.sheets.prefix(model.sheetIndex).reduce(0) { $0+$1.repeatCount }+model.repetition+1,kind:model.side),generatedBleed: model.plan.generatedBleed,bleedAmount:model.project.settings.bleed,tone:model.project.settings.tone,
                              highlighted: model.highlightedSlots,zoomAction: model.zoomAction,zoomFactor:model.zoomFactor,zoomModel:model,focusArea:model.ui.focusedArea,moveSheet:model.movePreviewSheet,
                              repetition: model.repetition,selectedSerial: model.selectedSerialID,
                              selectSerial: model.selectSerial,moveSerial: { model.moveSerialField($0,to: $1,snap:false) },controlMarks: model.project.exportMarks,moveGangBlock: { model.moveGangBlock($0,to:$1) },beginEdit:model.beginUndoGroup,endEdit:model.endUndoGroup)
            } else if model.source == nil {
                HomeEmptyStateView(model: model)
            } else {
                ContentUnavailableView("Önizleme oluşturulamadı",systemImage: "exclamationmark.triangle",
                    description: Text("Sayfa seçimini ve aşağıdaki doğrulama mesajlarını kontrol edin."))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            if let summary = model.exportSummary {
                HStack {
                    Text(summary).font(.system(size:12))
                    Spacer()
                    if !model.exportedFiles.isEmpty {
                        Button("Klasörde göster",action:model.revealExport).font(.system(size:12))
                        Button("Aç") { if let url = model.exportedFiles.first { NSWorkspace.shared.open(url) } }.font(.system(size:12))
                    }
                }.padding(8)
            }
            ForEach(model.exportNotes,id:\.self) { Text(TRFormat.presentation($0)).font(.system(size:12)).foregroundStyle(DesignSystem.muted).padding(.horizontal,8) }
            if let verification = model.exportVerification {
                Text(verification.label).font(.system(size:12)).foregroundStyle(verification.passed ? DesignSystem.success : DesignSystem.error).padding(.horizontal,8)
            }
            Divider()
            HStack(spacing:DesignSystem.Space.md) {
                if !model.project.hasPanelItems {
                    Label(model.source==nil ? "PDF seçin":"Baskıya dahil sayfa yok",systemImage:"doc.badge.plus")
                } else if model.workflowIssues.isEmpty {
                    Label(model.workflowReadyText,systemImage:"checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.success).padding(DesignSystem.Space.sm)
                        .background(DesignSystem.successSurface,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
                } else {
                    Menu {
                        ForEach(Array(model.workflowIssues.enumerated()),id:\.offset) { _,issue in Button(TRFormat.presentation(issue.message)) { model.revealWorkflowIssue(issue) } }
                    } label: {
                        let errors = model.workflowIssues.filter { $0.severity == .error }.count
                        let warnings = model.workflowIssues.filter { $0.severity == .warning }.count
                        Label("\(errors > 0 ? "\(errors) hata · " : "")\(warnings) uyarı · \(model.plan.totalPressSheets) tabaka",systemImage:errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    }.menuStyle(.borderlessButton).fixedSize().padding(DesignSystem.Space.sm)
                        .foregroundStyle(DesignSystem.warning).background(DesignSystem.warningSurface,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control))
                    if let first = model.workflowIssues.first {
                        Button(TRFormat.presentation(first.message)) { model.revealWorkflowIssue(first) }.buttonStyle(.plain).font(.system(size:12)).lineLimit(2).accessibilityLabel("Ayarı göster: "+TRFormat.presentation(first.message))
                    }
                }
                if model.requiresBacklessConfirmation {Text("Arka yüz yok").foregroundStyle(DesignSystem.warning)}
                Text(!model.project.hasPanelItems ? "" : model.cropMarkStatus).font(.system(size:12)).foregroundStyle(DesignSystem.muted)
                if let summary = model.currentSheet?.productionSummary { Text(summary).font(.system(size:12)).foregroundStyle(DesignSystem.muted).lineLimit(1) }
                Spacer(minLength:0)
            }.font(.callout).padding(DesignSystem.Space.md)

        }
    }
}
