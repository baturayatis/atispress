import SwiftUI
import AppKit
import ImpositionCore

/// Native semantic surfaces; brand pairs have explicit light/dark contrast tests.
enum DesignSystem {
    enum Space { static let xs:CGFloat = 4, sm:CGFloat = 8, md:CGFloat = 12, lg:CGFloat = 16, xl:CGFloat = 24 }
    enum Radius { static let control:CGFloat = 8, card:CGFloat = 12 }
    static let minimumWindow = CGSize(width:1180,height:760)
    static let inspectorWidth:CGFloat = 400
    static let lightPairs:[String:(UInt32,UInt32)] = ["primary":(0xFFFFFF,0x16213E),"action":(0xFFFFFF,0x0B7F86),"success":(0x17613A,0xE3F4EA),"warning":(0x8A4B00,0xFFF3E0),"paperFocus":(0x0B7F86,0xFFFFFF),"paperAnnotation":(0x60458C,0xFFFFFF),"paperError":(0xAA212B,0xFFFFFF)]
    static let darkPairs:[String:(UInt32,UInt32)] = ["primary":(0xEAF0FF,0x273656),"action":(0xFFFFFF,0x086970),"success":(0xA0E0B9,0x183B29),"warning":(0xFFD08C,0x432C14),"paperFocus":(0x0B7F86,0xFFFFFF),"paperAnnotation":(0x60458C,0xFFFFFF),"paperError":(0xAA212B,0xFFFFFF)]
    static func rgb(_ hex:UInt32) -> NSColor { NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1) }
    static func adaptive(_ light:UInt32,_ dark:UInt32) -> NSColor { NSColor(name:nil) { appearance in rgb(appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark : light) } }
    private static func pair(_ key:String,_ foreground:Bool) -> Color {
        let a = lightPairs[key]!,b = darkPairs[key]!
        return Color(nsColor:adaptive(foreground ? a.0 : a.1,foreground ? b.0 : b.1))
    }
    static let navy = Color(nsColor:adaptive(0x16213E,0xB9C8EF))
    static let teal = Color(nsColor:adaptive(0x0B7F86,0x73D8DE))
    static let selected = pair("primary",false), selectedText = pair("primary",true)
    static let action = pair("action",false), actionText = pair("action",true)
    static let success = pair("success",true), successSurface = pair("success",false)
    static let warning = pair("warning",true), warningSurface = pair("warning",false)
    static let error = Color(nsColor:adaptive(0xAA212B,0xFFADB4))
    static let errorSurface = Color(nsColor:adaptive(0xFDEBED,0x461C24))
    static let text = Color.primary
    static let muted = Color(nsColor:adaptive(0x5B6270,0xB3BBC8))
    static let clear = Color.clear
    static let card = Color(nsColor:.controlBackgroundColor)
    static let workspaceNS = adaptive(0xECEEF2,0x1D2026)
    static let workspace = Color(nsColor:workspaceNS)
    static let border = Color(nsColor:.separatorColor)
    static let paperNS = NSColor.white, paper = Color(nsColor:paperNS)
    static let shadowNS = NSColor.black.withAlphaComponent(0.16)
    static let shadow = Color(nsColor:shadowNS)
    // Paper remains white, so its annotation/focus/error colors remain dark in both themes.
    static let focusNS = rgb(0x0B7F86)
    static let errorNS = rgb(0xAA212B)
    static let guideNS = rgb(0x868B94)
    static let blankNS = adaptive(0xF0F1F3,0xF0F1F3)
    static let purpleNS = rgb(0x60458C)
    static func jobTint(_ hue:Double,fill:Bool) -> NSColor { NSColor(calibratedHue:hue,saturation:fill ? 0.7 : 0.8,brightness:fill ? 0.85 : 0.45,alpha:fill ? 0.13 : 1) }
}
struct WorkflowCard<Content:View>: View {
    let number:Int?
    let title:String
    @ViewBuilder var content:Content
    init(_ number:Int? = nil,_ title:String,@ViewBuilder content:()->Content) { self.number = number; self.title = title; self.content = content() }
    init(_ title:String,@ViewBuilder content:()->Content) { self.number = nil; self.title = title; self.content = content() }
    var body:some View {
        VStack(alignment:.leading,spacing:DesignSystem.Space.lg) {
            HStack(spacing:DesignSystem.Space.sm) {
                if let number { Text(String(number)).font(.headline).foregroundStyle(DesignSystem.selectedText).frame(width:28,height:28).background(DesignSystem.selected,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.control)) }
                Text(title).font(.headline).foregroundStyle(DesignSystem.text)
                Spacer(minLength:0)
            }
            content
        }.padding(DesignSystem.Space.lg).frame(maxWidth:.infinity,alignment:.leading)
            .background(DesignSystem.card,in:RoundedRectangle(cornerRadius:DesignSystem.Radius.card))
            .overlay(RoundedRectangle(cornerRadius:DesignSystem.Radius.card).stroke(DesignSystem.border.opacity(0.45),lineWidth:0.5))
    }
}
struct AutomaticPill:View {
    @ObservedObject var model:Workspace
    let field:AutoLayoutField
    var body:some View {
        HStack(spacing:DesignSystem.Space.xs) {
            Text(model.isManual(field) || model.project.autoLayout?.presetFields?.contains(field) == true ? "Manuel" : "Otomatik")
                .font(.caption2).padding(.horizontal,6).padding(.vertical,2).background(.quaternary,in:Capsule())
            if model.isManual(field) || model.project.autoLayout?.presetFields?.contains(field) == true { Button("Otomatiğe döndür") { model.returnToAutomatic(field) }.buttonStyle(.borderless).font(.caption2).foregroundStyle(DesignSystem.teal).accessibilityLabel(SettingGuidance.title(field)+" otomatiğe döndür") }
        }
    }
}
