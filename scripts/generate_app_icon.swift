// Deterministic placeholder. Replace with packaging/AppIcon.icns for production artwork.
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
    NSColor(srgbRed: 0.08,green: 0.16,blue: 0.24,alpha: 1).setFill(); background.fill()
    NSColor(srgbRed: 0.96,green: 0.97,blue: 0.96,alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 235,y: 240,width: 554,height: 544),xRadius: 24,yRadius: 24).fill()
    // Four imposed cards and a shared trim cross, legible even at Finder's smallest size.
    NSColor(srgbRed: 0.06,green: 0.58,blue: 0.62,alpha: 1).setFill()
    for x in [265,527] {
        for y in [270,527] { NSRect(x: x,y: y,width: 232,height: 227).fill() }
    }
    NSColor(srgbRed: 0.96,green: 0.62,blue: 0.16,alpha: 1).setStroke()
    let crop = NSBezierPath(); crop.lineWidth = 14; crop.lineCapStyle = .square
    for x in [235.0,789.0] {
        crop.move(to: NSPoint(x: x,y: 185)); crop.line(to: NSPoint(x: x,y: 220))
        crop.move(to: NSPoint(x: x,y: 804)); crop.line(to: NSPoint(x: x,y: 839))
    }
    for y in [240.0,784.0] {
        crop.move(to: NSPoint(x: 180,y: y)); crop.line(to: NSPoint(x: 215,y: y))
        crop.move(to: NSPoint(x: 809,y: y)); crop.line(to: NSPoint(x: 844,y: y))
    }
    crop.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png,properties: [:]) else { fatalError("Cannot encode icon") }
    elements.append(Data(type.utf8)); elements.append(integer(data.count+8)); elements.append(data)
}

var icon = Data("icns".utf8)
icon.append(integer(elements.count+8)); icon.append(elements)
try icon.write(to: output,options: .atomic)
