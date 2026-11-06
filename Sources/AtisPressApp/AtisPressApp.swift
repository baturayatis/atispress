import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
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
                .onOpenURL { workspace.open($0) }
                .task {
                    // A file argument is useful with `swift run AtisPressApp /path/book.pdf`.
                    if let path = CommandLine.arguments.dropFirst().first, !path.hasPrefix("-") {
                        workspace.open(URL(fileURLWithPath: path))
                    }
                }
        }
        .defaultSize(width: 1440,height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("PDF Aç…") { workspace.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appInfo) {
                Button("AtışPress Hakkında") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "AtışPress", .applicationVersion: "Canlı önizleme — Adım 3"
                    ])
                }
            }
        }
    }
}
