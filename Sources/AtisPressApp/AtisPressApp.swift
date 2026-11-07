import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !workspace.loading,!workspace.exporting else { return .terminateCancel }
        return workspace.closeApproved || workspace.confirmDiscard() ? .terminateNow : .terminateCancel
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
    var body: some Scene {
        Window("AtışPress — Canlı Önizleme",id: "workspace") {
            WorkspaceView(model: workspace)
                .frame(minWidth: 1080,minHeight: 700)
                .background(ProjectWindowControl(model: workspace))
                .onOpenURL { workspace.open($0) }
                .task {
                    delegate.workspace = workspace
                    // A file argument is useful with `swift run AtisPressApp /path/book.pdf`.
                    if let path = CommandLine.arguments.dropFirst().first, !path.hasPrefix("-") {
                        workspace.open(URL(fileURLWithPath: path))
                    }
                }
        }
        .defaultSize(width: 1440,height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Yeni Proje") { workspace.createNewProject() }.keyboardShortcut("n")
                    .disabled(workspace.loading || workspace.exporting)
                Button("Aç…") { workspace.openPanel() }.keyboardShortcut("o")
                    .disabled(workspace.loading || workspace.exporting)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Kaydet") { workspace.chooseSave() }.keyboardShortcut("s")
                    .disabled(workspace.loading)
                Button("Farklı Kaydet…") { workspace.chooseSave(asNew: true) }.keyboardShortcut("s",modifiers: [.command,.shift])
                    .disabled(workspace.loading)
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
    }
}
