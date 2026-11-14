import SwiftUI
import ImpositionCore

/// AppKit keeps both the page symbol and text visible in every segment.
struct OrientationPicker:View {
    let title:String
    @Binding var selection:Orientation
    init(_ title:String,selection:Binding<Orientation>) { self.title = title; _selection = selection }
    var body:some View {
        HStack(spacing:DesignSystem.Space.sm) {
            Text(title)
            OrientationSegments(selection:$selection).frame(height:26)
        }
    }
}
private struct OrientationSegments:NSViewRepresentable {
    @Binding var selection:Orientation
    private let values:[Orientation] = [.auto,.landscape,.portrait]
    func makeCoordinator() -> Coordinator { Coordinator(selection:$selection) }
    func makeNSView(context:Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels:["Otomatik","Yatay","Dikey"],trackingMode:.selectOne,target:context.coordinator,action:#selector(Coordinator.changed(_:)))
        control.setAccessibilityLabel("Yön")
        control.selectedSegmentBezelColor = NSColor(DesignSystem.action)
        for (index,symbol) in ["doc.badge.gearshape","rectangle","rectangle.portrait"].enumerated() {
            let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:11,weight:.regular))
            control.setImage(image,forSegment:index)
            control.setImageScaling(.scaleProportionallyDown,forSegment:index)
        }
        return control
    }
    func updateNSView(_ control:NSSegmentedControl,context:Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = values.firstIndex(of:selection) ?? 0
    }
    final class Coordinator:NSObject {
        var selection:Binding<Orientation>
        init(selection:Binding<Orientation>) { self.selection = selection }
        @objc func changed(_ sender:NSSegmentedControl) {
            let values:[Orientation] = [.auto,.landscape,.portrait]
            if values.indices.contains(sender.selectedSegment) { selection.wrappedValue = values[sender.selectedSegment] }
        }
    }
}
