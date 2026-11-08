import SwiftUI
import AppKit

/// Retains SwiftUI's window delegate behavior while adding document close checks.
@MainActor
struct ProjectWindowControl: NSViewRepresentable {
    @ObservedObject var model: Workspace
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WindowHookView {
        let view = WindowHookView()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: WindowHookView,context: Context) { context.coordinator.update() }
    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: Workspace
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        private var editingObservers: [NSObjectProtocol] = []
        init(model: Workspace) {
            self.model = model
            super.init()
            let center = NotificationCenter.default
            editingObservers = [
                center.addObserver(forName:NSControl.textDidBeginEditingNotification,object:nil,queue:.main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self,let control = note.object as? NSControl,control.window === self.window else { return }
                        self.model.beginUndoGroup()
                    }
                },
                center.addObserver(forName:NSControl.textDidEndEditingNotification,object:nil,queue:.main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self,let control = note.object as? NSControl,control.window === self.window else { return }
                        self.model.endUndoGroup()
                    }
                }
            ]
        }
        deinit { for observer in editingObservers { NotificationCenter.default.removeObserver(observer) } }
        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window; original = window.delegate; window.delegate = self
            model.closeApproved = false
            update()
        }
        func update() {
            window?.isDocumentEdited = model.isModified
            window?.representedURL = model.projectURL
            window?.title = (model.projectURL?.lastPathComponent ?? "Yeni Proje")+" — AtışPress"
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !model.loading,!model.exporting,!model.autoArranging,model.confirmDiscard() else { return false }
            if let original,original.windowShouldClose?(sender) == false { return false }
            model.closeApproved = true
            model.cleanRecoveryForNormalQuit()
            return true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || MainActor.assumeIsolated { original?.responds(to: selector) ?? false }
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if let target = MainActor.assumeIsolated({ original?.responds(to: selector) == true ? original : nil }) { return target }
            return super.forwardingTarget(for: selector)
        }
    }
}
final class WindowHookView: NSView {
    var attach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { attach?(window) }
    }
}
