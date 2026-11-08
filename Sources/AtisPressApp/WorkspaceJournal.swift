import Foundation
import CoreFoundation
import PDFEngine

@MainActor
struct EditSnapshot {
    var state: ProjectState
    var source: PDFSource?
    var assets: [Workspace.GangAsset]
}
@MainActor
final class WorkspaceJournal {
    private var observed: EditSnapshot?
    private var undoStack: [(EditSnapshot,EditSnapshot)] = []
    private var redoStack: [(EditSnapshot,EditSnapshot)] = []
    private var pending: (EditSnapshot,EditSnapshot)?
    private var key = ""
    private var depth = 0
    var canUndo: Bool { pending != nil || !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func reset(_ snapshot: EditSnapshot) { observed = snapshot; undoStack = []; redoStack = []; pending = nil; depth = 0 }
    func rebase(_ snapshot: EditSnapshot) { observed = snapshot }
    func beginGroup() { flush(); depth += 1 }
    func endGroup() { depth = max(0,depth-1); if depth == 0 { flush() } }
    func observe(_ snapshot: EditSnapshot) {
        guard let old = observed else { observed = snapshot; return }
        observed = snapshot
        guard Self.meaningful(old.state) != Self.meaningful(snapshot.state) else { return }
        let paths = Self.paths(old.state,snapshot.state)
        let nextKey = paths.sorted().joined(separator:"|")
        if depth == 0,key != nextKey { flush() }
        if let before = pending?.0 { pending = (before,snapshot) } else { pending = (old,snapshot) }
        key = nextKey; redoStack = []
        // Page selections/order and structural arrays are discrete actions. Numeric
        // and text field updates coalesce until debounce/focus change ends them.
        let discrete = paths.contains(where:{ $0.hasPrefix("order") || $0.hasPrefix("included") || ["binding","orientation","turnMethod","edge","method","behavior"].contains($0.components(separatedBy:".").last ?? "") })
        if depth == 0 && (discrete || Self.hasDiscreteValue(snapshot.state,paths:paths)) { flush() }
    }
    func flush() {
        guard depth == 0,let pending else { return }
        if Self.meaningful(pending.0.state) != Self.meaningful(pending.1.state) {
            undoStack.append(pending); if undoStack.count>100 { undoStack.removeFirst() }
        }
        self.pending = nil; key = ""
    }
    func undo() -> EditSnapshot? {
        flush(); guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry); observed = entry.0; return entry.0
    }
    func redo() -> EditSnapshot? {
        flush(); guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry); observed = entry.1; return entry.1
    }
    private static func meaningful(_ state: ProjectState) -> ProjectState {
        var s = state; s.sheetIndex = 0; s.side = .front; s.repetition = 0; return s
    }
    private static func hasDiscreteValue(_ state: ProjectState,paths: Set<String>) -> Bool {
        guard let data = try? JSONEncoder().encode(state),let json = try? JSONSerialization.jsonObject(with:data) else { return false }
        for path in paths {
            var value: Any? = json
            for component in path.components(separatedBy:".") {
                if let dict = value as? [String:Any] { value = dict[component] }
                else if let array = value as? [Any],let i = Int(component),array.indices.contains(i) { value = array[i] }
                else { value = nil; break }
            }
            if value is [Any] { return true }
            if let number = value as? NSNumber,CFGetTypeID(number) == CFBooleanGetTypeID() { return true }
        }
        return false
    }
    private static func paths(_ a: ProjectState,_ b: ProjectState) -> Set<String> {
        let encoder = JSONEncoder()
        guard let ad = try? encoder.encode(meaningful(a)),let bd = try? encoder.encode(meaningful(b)),
              let aj = try? JSONSerialization.jsonObject(with:ad),let bj = try? JSONSerialization.jsonObject(with:bd) else { return ["ayar"] }
        func diff(_ x: Any?,_ y: Any?,_ path: String) -> Set<String> {
            if path.hasPrefix("project.autoLayout") { return [] }
            if let x = x as? [String:Any],let y = y as? [String:Any] {
                return Set(x.keys).union(y.keys).reduce(into:Set<String>()) { out,k in out.formUnion(diff(x[k],y[k],path.isEmpty ? k : path+"."+k)) }
            }
            if let x = x as? [Any],let y = y as? [Any],x.count == y.count {
                return x.indices.reduce(into:Set<String>()) { out,i in out.formUnion(diff(x[i],y[i],path+".\(i)")) }
            }
            if let x = x as? NSObject,let y = y as? NSObject,x == y { return [] }
            return [path]
        }
        return diff(aj,bj,"")
    }
}
