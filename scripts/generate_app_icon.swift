// Deterministic navy imposition glyph. Override with packaging/AppIcon.icns.
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: generate_app_icon.swift output.icns") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
// ICNS contains big-endian length-prefixed elements holding standard PNG images.
func integer(_ number: Int) -> Data {
    var value = UInt32(number).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var elements = Data()
let representations = [(16,1,"icp4"),(16,2,"ic11"),(32,1,"icp5"),(32,2,"ic12"),
                       (128,1,"ic07"),(128,2,"ic13"),(256,1,"ic08"),(256,2,"ic14"),
                       (512,1,"ic09"),(512,2,"ic10")]
for (points,scale,type) in representations {
    let pixels = points*scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: pixels,pixelsHigh: pixels,
        bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,
        bytesPerRow: 0,bitsPerPixel: 0),let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(pixels)/1024,y: CGFloat(pixels)/1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 80,y: 80,width: 864,height: 864),xRadius: 190,yRadius: 190)
    NSColor(srgbRed:0.035,green:0.075,blue:0.14,alpha:1).setFill(); background.fill()
    // A white sheet outline, folded upper-right corner and shared imposition cuts.
    NSColor.white.setStroke()
    let sheet = NSBezierPath(); sheet.lineWidth = 28; sheet.lineJoinStyle = .round; sheet.lineCapStyle = .round
    sheet.move(to:NSPoint(x:280,y:245)); sheet.line(to:NSPoint(x:744,y:245))
    sheet.line(to:NSPoint(x:744,y:650)); sheet.line(to:NSPoint(x:625,y:779))
    sheet.line(to:NSPoint(x:280,y:779)); sheet.close(); sheet.stroke()
    let folds = NSBezierPath(); folds.lineWidth = 24; folds.lineCapStyle = .round; folds.lineJoinStyle = .round
    folds.move(to:NSPoint(x:625,y:779)); folds.line(to:NSPoint(x:625,y:650)); folds.line(to:NSPoint(x:744,y:650))
    folds.move(to:NSPoint(x:512,y:270)); folds.line(to:NSPoint(x:512,y:750))
    folds.move(to:NSPoint(x:305,y:505)); folds.line(to:NSPoint(x:719,y:505)); folds.stroke()
    NSColor(srgbRed:0.14,green:0.8,blue:0.72,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:672,y:195,width:112,height:112),xRadius:30,yRadius:30).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png,properties: [:]) else { fatalError("Cannot encode icon") }
    elements.append(Data(type.utf8)); elements.append(integer(data.count+8)); elements.append(data)
}

var icon = Data("icns".utf8)
icon.append(integer(elements.count+8)); icon.append(elements)
try icon.write(to: output,options: .atomic)
