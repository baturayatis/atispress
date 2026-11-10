import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace? { didSet { drainOpenRequests() } }
    private var pendingOpenURLs: [URL] = []
    private var openTask: Task<Void,Never>?
    private var lastRequest: (URL,Date)?
    func application(_ application: NSApplication,open urls: [URL]) { receiveOpenURLs(urls) }
    func receiveOpenURLs(_ urls: [URL]) {
        for url in urls where OpenFileKind.any.accepts(url) {
            // AppKit and SwiftUI may both deliver the same native event.
            if let lastRequest,lastRequest.0 == url,Date().timeIntervalSince(lastRequest.1)<0.5 { continue }
            lastRequest = (url,Date()); pendingOpenURLs.append(url)
        }
        if !pendingOpenURLs.isEmpty { NSApplication.shared.activate(ignoringOtherApps:true) }
        drainOpenRequests()
    }
    private func drainOpenRequests() {
        guard workspace != nil,openTask == nil,!pendingOpenURLs.isEmpty else { return }
        openTask = Task { [weak self] in
            guard let self else { return }
            defer { self.openTask = nil }
            while !self.pendingOpenURLs.isEmpty,let workspace = self.workspace {
                if workspace.loading || workspace.exporting || workspace.autoArranging {
                    try? await Task.sleep(for:.milliseconds(30)); continue
                }
                let url = self.pendingOpenURLs.removeFirst()
                workspace.open(url)
                await Task.yield()
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !workspace.loading,!workspace.exporting,!workspace.autoArranging else { return .terminateCancel }
        let approved = workspace.closeApproved || workspace.confirmDiscard()
        if approved { workspace.cleanRecoveryForNormalQuit() }
        return approved ? .terminateNow : .terminateCancel
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationDidUpdate(_ notification: Notification) {
        // SwiftUI installs the standard menus after launch; update their Turkish titles when ready.
        let titles = ["File":"Dosya", "Edit":"Düzenle", "View":"Görünüm", "Window":"Pencere", "Help":"Yardım"]
        for item in NSApplication.shared.mainMenu?.items ?? [] {
            if let title = titles[item.title] { item.title = title; item.submenu?.title = title }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AtisPressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var workspace = Workspace()
    @StateObject private var prices = PricingStore()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("AtışPress — Canlı Önizleme",id: "workspace") {
            WorkspaceView(model: workspace)
                .frame(minWidth: 1080,minHeight: 700)
                .background(ProjectWindowControl(model: workspace))
                .onOpenURL { delegate.receiveOpenURLs([$0]) }
                .task {
                    workspace.startPersistence()
                    await workspace.offerRecoveryOnLaunch()
                    delegate.workspace = workspace
                    // A file argument is useful with `swift run AtisPressApp /path/book.pdf`.
                    if let path = CommandLine.arguments.dropFirst().first, !path.hasPrefix("-") {
                        workspace.open(URL(fileURLWithPath: path))
                    }
                }
        }
        .defaultSize(width: 1440,height: 920)
        .commands {
            CommandGroup(replacing:.undoRedo) {
                Button("Geri Al") { workspace.undoEdit() }.keyboardShortcut("z").disabled((!workspace.canUndo && !(NSApp?.keyWindow?.firstResponder is NSTextView)) || workspace.loading || workspace.autoArranging || workspace.exporting)
                Button("Yinele") { workspace.redoEdit() }.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!workspace.canRedo || workspace.loading || workspace.autoArranging || workspace.exporting)
            }
            CommandMenu("Fiyatlar") {
                Button("Fiyatlar…") { openWindow(id:"prices") }
                Button("İş maliyeti…") { openWindow(id:"costing") }
            }
            CommandMenu("Hazır ayarlar") {
                Menu("Hazır ayar uygula") {
                    ForEach(workspace.presets) { preset in Button(preset.name) { workspace.applyPreset(preset) } }
                }
                Button("Yeni hazır ayar kaydet…",action:workspace.promptSavePreset)
                Button("Yeniden adlandır…",action:workspace.promptRenamePreset).disabled(workspace.selectedPresetID == nil)
                Button("Çoğalt") {
                    if let id = workspace.selectedPresetID { do { try workspace.duplicatePreset(id) } catch { workspace.error = error.localizedDescription } }
                }.disabled(workspace.selectedPresetID == nil)
                Button("Sil") {
                    if let id = workspace.selectedPresetID { do { try workspace.deletePreset(id) } catch { workspace.error = error.localizedDescription } }
                }.disabled(workspace.selectedPresetID == nil)
                Divider()
                Button("Paket içe aktar…",action:workspace.choosePresetImport)
                Button("Paket dışa aktar…",action:workspace.choosePresetExport)
            }
            CommandGroup(replacing: .newItem) {
                Button("Yeni Proje") { workspace.createNewProject() }.keyboardShortcut("n")
                    .disabled(workspace.loading || workspace.exporting || workspace.autoArranging)
                Button("Aç…") { workspace.openPanel() }.keyboardShortcut("o")
                    .disabled(workspace.loading || workspace.exporting || workspace.autoArranging)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Kaydet") { workspace.chooseSave() }.keyboardShortcut("s")
                    .disabled(workspace.loading || workspace.autoArranging)
                Button("Farklı Kaydet…") { workspace.chooseSave(asNew: true) }.keyboardShortcut("s",modifiers: [.command,.shift])
                    .disabled(workspace.loading || workspace.autoArranging)
                Divider()
                Button("PDF Dışa Aktar…") { workspace.chooseExport(perSheet: false) }
                    .keyboardShortcut("e",modifiers: [.command,.shift]).disabled(!workspace.canExportNow)
                Button("Her Tabaka İçin PDF…") { workspace.chooseExport(perSheet: true) }.disabled(!workspace.canExportNow)
            }
            CommandGroup(replacing: .appInfo) {
                Button("AtışPress Hakkında") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "AtışPress", .applicationVersion: "PDF dışa aktarma — Adım 4"
                    ])
                }
            }
        }
        Window("Fiyatlar",id:"prices") { PricingView(store:prices) }
        Window("İş maliyeti",id:"costing") { CostingView(model:workspace,store:prices) }
    }
}
