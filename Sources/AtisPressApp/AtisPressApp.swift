import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace? { didSet { drainOpenRequests() } }
    weak var mainWindow: NSWindow?
    var beganUpdateLaunch = false
    var manualUpdateAfterConsent = false

    var canPresentUpdateWindow: Bool {
        guard let workspace, let mainWindow, mainWindow.isVisible,
              NSApp.keyWindow === mainWindow, NSApp.modalWindow == nil,
              !NSApp.windows.contains(where:{ $0.isVisible && ($0 is NSSavePanel || $0.attachedSheet != nil) }),
              !UpdateChecker.shared.busy else { return false }
        return !workspace.hasPendingUpdatePresentationBlocker
    }

    private var pendingOpenURLs: [URL] = []
    private var openTask: Task<Void,Never>?
    private var recentRequests: [URL: Date] = [:]
    func application(_ application: NSApplication,open urls: [URL]) { receiveOpenURLs(urls) }
    func receiveOpenURLs(_ urls: [URL], activate: Bool = true) {
        let now = Date()
        recentRequests = recentRequests.filter { now.timeIntervalSince($0.value) < 0.5 }
        for url in urls where OpenFileKind.any.accepts(url) {
            // AppKit and SwiftUI may both deliver each member of the native event.
            let key = url.standardizedFileURL
            guard recentRequests[key] == nil else { continue }
            recentRequests[key] = now
            pendingOpenURLs.append(url)
        }
        if activate && !pendingOpenURLs.isEmpty { NSApplication.shared.activate(ignoringOtherApps: true) }
        drainOpenRequests()
    }

    private func drainOpenRequests() {
        guard workspace != nil, openTask == nil, !pendingOpenURLs.isEmpty else { return }
        openTask = Task { [weak self] in
            guard let self else { return }
            defer { openTask = nil }
            // SwiftUI can deliver a multi-file request as consecutive per-URL callbacks.
            try? await Task.sleep(for: .milliseconds(50))
            while !pendingOpenURLs.isEmpty, let workspace {
                if workspace.loading || workspace.preparingSource || workspace.exporting || workspace.autoArranging {
                    try? await Task.sleep(for: .milliseconds(30))
                    continue
                }
                if OpenFileKind.pdf.accepts(pendingOpenURLs[0]) {
                    let batch = pendingOpenURLs.prefix(while: OpenFileKind.pdf.accepts)
                    pendingOpenURLs.removeFirst(batch.count)
                    workspace.openExternalPDFs(Array(batch))
                } else {
                    workspace.open(pendingOpenURLs.removeFirst())
                }
                await Task.yield()
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !workspace.preparingSource,!workspace.loading,!workspace.exporting,!workspace.autoArranging else { return .terminateCancel }
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
    @StateObject private var workspace = Workspace(restoreInspector:false)
    @StateObject private var prices = PricingStore()
    @StateObject private var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("AtışPress — Canlı Önizleme",id: "workspace") {
            WorkspaceView(model:workspace,prices:prices)
                .frame(minWidth:DesignSystem.minimumWindow.width,minHeight:DesignSystem.minimumWindow.height)
                .background(ProjectWindowControl(model:workspace,onWindow:{ delegate.mainWindow = $0 }))
                .onOpenURL { delegate.receiveOpenURLs([$0]) }
                .task {
                    workspace.ui.railVisible = true
                    workspace.ui.inspectorCollapsed = false
                    workspace.ui.jump(.job)
                    workspace.startPersistence()
                    await workspace.offerRecoveryOnLaunch()
                    delegate.workspace = workspace
                    // A file argument is useful with `swift run AtisPressApp /path/book.pdf`.
                    if let path = CommandLine.arguments.dropFirst().first, !path.hasPrefix("-") {
                        workspace.open(URL(fileURLWithPath: path))
                    }
                    await startLaunchUpdate()
                }
        }
        .defaultSize(width: 1440,height: 920)
        .commands {
            CommandGroup(replacing:.undoRedo) {
                Button("Geri Al") { workspace.undoEdit() }.keyboardShortcut("z").disabled((!workspace.canUndo && !(NSApp?.keyWindow?.firstResponder is NSTextView)) || workspace.loading || workspace.autoArranging || workspace.exporting)
                Button("Yinele") { workspace.redoEdit() }.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!workspace.canRedo || workspace.loading || workspace.autoArranging || workspace.exporting)
            }
            CommandGroup(after:.toolbar) {
                Toggle("Simge çubuğunu göster",isOn:Binding(get:{workspace.ui.railVisible},set:{workspace.ui.railVisible=$0}))
                Toggle("Denetçiyi daralt",isOn:Binding(get:{workspace.ui.inspectorCollapsed},set:{workspace.ui.inspectorCollapsed=$0}))
                Menu("Sağ panele git") {
                    ForEach(InspectorPanel.allCases) { panel in
                        Button(panel.title) { workspace.ui.jump(panel) }
                    }
                    Divider()
                    ForEach(InspectorPanel.shortcuts) { shortcut in
                        let group = shortcut.destination(for: workspace.project)
                        Button(group.title) { workspace.ui.jump(shortcut.panel, opening: group) }
                            .keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.optionKey == nil ? .command : [.command,.option])
                            .disabled(!shortcut.isAvailable(for: workspace.project))
                    }
                }
                Divider()

                Picker("Görünüm",selection:Binding(get:{ workspace.showsAllSides },set:{ workspace.showsAllSides = $0 })) {
                    Text("Tüm yüzler").tag(true); Text("Tek yüz").tag(false)
                }
                Button("Ön yüz") { workspace.side = .front }
                Button("Arka yüz") { workspace.side = .back }
                Button("Önceki tabaka") { workspace.movePreviewSheet(-1) }
                Button("Sonraki tabaka") { workspace.movePreviewSheet(1) }
                Divider()
                Button("Sığdır") { workspace.zoomFactor = 0; workspace.zoomAction += 1 }.keyboardShortcut("0")
                Button("Yakınlaştır") { workspace.zoomFactor = 1.25; workspace.zoomAction += 1 }.keyboardShortcut("+")
                Button("Uzaklaştır") { workspace.zoomFactor = 1/1.25; workspace.zoomAction += 1 }.keyboardShortcut("-")
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
                Button("PDF’i Hazırla…") { workspace.preparingExport = true }.keyboardShortcut("e").disabled(!workspace.canExportNow)
                Button("PDF Dışa Aktar…") { workspace.chooseExport(perSheet: false) }
                    .keyboardShortcut("e",modifiers: [.command,.shift]).disabled(!workspace.canExportNow)
                Button("Her Tabaka İçin PDF…") { workspace.chooseExport(perSheet: true) }.disabled(!workspace.canExportNow)
            }
            CommandGroup(replacing:.help) {
                Button("Hata bildir…") { openWindow(id:"report") }
                Button("AtışPress Hakkında") { openWindow(id:"about") }
                Button("Güncellemeleri denetle…",action:checkUpdatesManually)
                if let title = updates.badgeTitle {
                    Button(title) { openWindow(id:"updates") }
                        .accessibilityIdentifier("updates.helpBadge")
                }
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("Ayarlar…") }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("AtışPress Hakkında") { openWindow(id:"about") }
            }
        }
        Settings { TeamPDFImportSettings(settings:workspace.ui,updates:updates) }
        Window("Güncelleme izni",id:"update-consent") {
            UpdateConsentPanel(answer:answerUpdateConsent)
        }.windowResizability(.contentSize)
        Window("Hata bildir…",id:"report") { HelpPanel(model:workspace,mode:"Hata bildir…") }
        Window("AtışPress Hakkında",id:"about") { HelpPanel(model:workspace,mode:"AtışPress Hakkında") }
        Window("Güncellemeleri denetle…",id:"updates") { UpdatePanel(model:workspace,checker:updates) }
        Window("Fiyatlar",id:"prices") { PricingView(store:prices) }
        Window("İş maliyeti",id:"costing") { CostingView(model:workspace,store:prices) }
    }

    private func startLaunchUpdate() async {
        while delegate.mainWindow?.isVisible != true {
            do { try await Task.sleep(for:.milliseconds(30)) } catch { return }
        }
        guard !Task.isCancelled, !delegate.beganUpdateLaunch else { return }
        delegate.beganUpdateLaunch = true
        if updates.automaticConsent == nil {
            while !delegate.canPresentUpdateWindow {
                do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
                guard delegate.mainWindow?.isVisible == true, updates.automaticConsent == nil else { return }
            }
            openWindow(id:"update-consent")
        } else {
            await presentLaunchUpdate()
        }
    }

    private func presentLaunchUpdate() async {
        let started = ProcessInfo.processInfo.systemUptime
        guard await updates.checkOnLaunch() != nil, !Task.isCancelled,
              ProcessInfo.processInfo.systemUptime-started <= 30, delegate.canPresentUpdateWindow else { return }
        openWindow(id:"updates")
    }

    private func checkUpdatesManually() {
        guard updates.automaticConsent != nil else {
            delegate.manualUpdateAfterConsent = true
            openWindow(id:"update-consent")
            return
        }
        updates.check()
        openWindow(id:"updates")
    }

    private func answerUpdateConsent(_ enabled: Bool) {
        updates.setAutomaticConsent(enabled)
        if delegate.manualUpdateAfterConsent {
            delegate.manualUpdateAfterConsent = false
            checkUpdatesManually()
        } else {
            Task {
                // Let the consent window close before an already cached result can open.
                for _ in 0..<10 {
                    guard !delegate.canPresentUpdateWindow else { break }
                    try? await Task.sleep(for:.milliseconds(30))
                }
                await presentLaunchUpdate()
            }
        }
    }

}
