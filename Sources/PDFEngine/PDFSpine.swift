import AppKit
import CoreText
import ImpositionCore

public enum PDFSpine {
    public struct TextLayout {
        public let bounds: CGRect
        public let overflow: CGSize
        public let size: Double
        let line: CTLine
        let path: CGPath
        let transform: CGAffineTransform
    }

    public static func color(_ value: BleedColor) -> CGColor {
        CGColor(colorSpace: value.components.count == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB(),
                components: value.components.map { CGFloat($0) } + [1])!
    }

    public static func layout(_ block: SpineContent.TextBlock, at position: SpineContent.Position,
                              in trim: CGRect) -> TextLayout? {
        guard !block.text.isEmpty, trim.width > 0, trim.height > 0 else { return nil }
        func shape(_ size: Double) -> (CTLine, CGPath)? {
            let font = CTFontCreateWithName(block.font as CFString, size/PDFPreviewDrawing.pointsPerMM, nil)
            guard (CTFontCopyPostScriptName(font) as String) == block.font else { return nil }
            var traits: CTFontSymbolicTraits = []
            if block.bold { traits.insert(.boldTrait) }
            if block.italic { traits.insert(.italicTrait) }
            let face = traits.isEmpty ? font : CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits)
            guard let face else { return nil }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: block.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):face,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):color(block.color)
            ]))
            let path = CGMutablePath()
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName as String] as! CTFont
                if !block.outlines,
                   let table = CTFontCopyTable(runFont, CTFontTableTag(kCTFontTableOS2), []) as Data?,
                   table.count >= 10 {
                    let restrictions = UInt16(table[8]) << 8 | UInt16(table[9])
                    // Quartz subsets fonts, so exclude faces that restrict embedding, subsetting or outlines.
                    if restrictions & 0x0302 != 0 { return nil }
                }
                let count = CTRunGetGlyphCount(run)
                let range = CFRange(location: 0, length: count)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, range, &glyphs)
                CTRunGetPositions(run, range, &positions)
                var indices = [CFIndex](repeating:0,count:count)
                CTRunGetStringIndices(run,range,&indices)
                let text = block.text as NSString
                for index in glyphs.indices {
                    let glyph = glyphs[index]
                    guard glyph != 0 else { return nil }
                    if let glyphPath = CTFontCreatePathForGlyph(runFont,glyph,nil) {
                        let point = positions[index]
                        path.addPath(glyphPath,transform:CGAffineTransform(translationX:point.x,y:point.y))
                    } else {
                        let location = indices[index]
                        guard (0..<text.length).contains(location),
                              let scalar = UnicodeScalar(text.character(at:location)),
                              CharacterSet.whitespaces.contains(scalar) else { return nil }
                    }
                }
            }
            return (line, path)
        }

        let regionHeight = trim.height/3
        let regionBottom = position == .top ? 2*regionHeight : position == .middle ? regionHeight : 0
        let alignTop = (block.alignment == .start && !block.bottomUp) || (block.alignment == .end && block.bottomUp)
        let angle: CGFloat = block.bottomUp ? .pi/2 : -.pi/2
        let rotation = CGAffineTransform(rotationAngle: angle)
        var size = block.size
        guard var (line, path) = shape(size) else { return nil }
        if block.autoFit, !path.isEmpty {
            let ink = path.boundingBoxOfPath.applying(rotation)
            let availableWidth = trim.width-2*abs(block.x)
            let anchor = regionBottom + block.y
            let availableHeight: CGFloat
            if block.alignment == .center {
                let center = anchor+regionHeight/2
                availableHeight = min(regionHeight,2*min(center,trim.height-center))
            } else if alignTop {
                let top = anchor+regionHeight
                availableHeight = top <= trim.height ? min(regionHeight,top) : 0
            } else {
                availableHeight = anchor >= 0 ? min(regionHeight,trim.height-anchor) : 0
            }
            if availableWidth > 0, availableHeight > 0 {
                size = max(0.01, min(1000, size*min(availableWidth/ink.width, availableHeight/ink.height)*0.9999))
                guard let fitted = shape(size) else { return nil }
                (line,path) = fitted
            }
        }
        let ink = path.isEmpty ? CGRect.zero : path.boundingBoxOfPath.applying(rotation)
        let y = block.alignment == .center ? regionBottom+(regionHeight-ink.height)/2 :
            alignTop ? regionBottom+regionHeight-ink.height : regionBottom
        let tx = trim.midX-ink.midX+block.x
        let ty = trim.minY+y-ink.minY+block.y
        let bounds = ink.offsetBy(dx:tx,dy:ty)
        let overflow = path.isEmpty ? CGSize.zero : CGSize(
            width: max(0,trim.minX-bounds.minX)+max(0,bounds.maxX-trim.maxX),
            height: max(0,trim.minY-bounds.minY)+max(0,bounds.maxY-trim.maxY))
        let transform = rotation.concatenating(CGAffineTransform(translationX:tx,y:ty))
        return TextLayout(bounds:bounds,overflow:overflow,size:size,line:line,path:path,transform:transform)
    }

    public static func warning(_ block: SpineContent.TextBlock, at position: SpineContent.Position, in trim: CGRect) -> String? {
        guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let layout = layout(block, at:position, in:trim) else {
            return "Yazı tipi veya biçimi kullanılamıyor. Başka bir yazı tipi seçin ya da yazıyı eğriye çevirin."
        }
        guard layout.overflow.width > 0.00001 || layout.overflow.height > 0.00001 else { return nil }
        return String(format:"Sırt yazısı taşıyor · En: %.4f mm · Boy: %.4f mm", locale:Locale(identifier:"tr_TR"),
                      layout.overflow.width, layout.overflow.height)
    }

    public static func issues(in plan: ImpositionPlan) -> [ValidationIssue] {
        var messages = Set<String>()
        for sheet in plan.sheets {
            for slot in sheet.front.slots+sheet.back.slots {
                guard let content = slot.spineArtwork?.content, content.mode == .text else { continue }
                for position in SpineContent.Position.allCases {
                    if let block = content.blocks[position],
                       let message = warning(block, at:position, in:PDFPreviewDrawing.localTrim(slot)) {
                        messages.insert(message)
                    }
                }
            }
        }
        return messages.sorted().map { ValidationIssue(.error,.bookSettings,$0) }
    }
}

public struct PDFSpineOverlay: PDFSlotOverlay, @unchecked Sendable {
    public var phase: PDFOverlayPhase { .overArtwork }
    private let document: CGPDFDocument
    private let samples: PDFEdgeSampleCache
    private let tone: ArtworkTone?
    public init(document: CGPDFDocument, samples: PDFEdgeSampleCache, tone: ArtworkTone? = nil) {
        self.document = document; self.samples = samples; self.tone = tone
    }

    public func draw(in context: CGContext, placement: PDFSlotContext) throws {
        guard let artwork = placement.slot.spineArtwork else { return }
        let content = artwork.content
        let trim = placement.trimRect
        switch content.mode {
        case .empty: break
        case .color:
            if !content.extendEdges {
                context.setFillColor(PDFSpine.color(content.color))
                context.fill(placement.artworkRect)
                return
            }
            for (number,edge,x) in [(artwork.backPage,SampleEdge.right,trim.minX),(artwork.frontPage,.left,trim.midX)] {
                guard let number, let page = document.page(at:number),
                      let strip = try samples.samples(for:page).strips[edge] else { throw PDFExportError.invalidGeometry }
                let width = trim.width/2
                if artwork.vectorExtension && strip.uniformColor(tolerance:0) == nil {
                    extendVector(page,edge:edge,strip:strip,x:x,width:width,trim:trim,clip:placement.artworkRect,in:context)
                } else {
                    strip.drawExtension(x:x,width:width,trim:trim,bleed:placement.artworkRect,in:context)
                }
                let amount = tone?.value(forPage: number, side: placement.slot.itemSide ?? placement.reference.side) ?? 0
                if amount != 0 {
                    context.setFillColor(CGColor(gray:amount > 0 ? 1 : 0,alpha:Double(abs(amount))/100))
                    context.fill(CGRect(x:x,y:placement.artworkRect.minY,width:width,height:placement.artworkRect.height))
                }
            }
        case .text:
            for position in SpineContent.Position.allCases {
                guard let block = content.blocks[position],
                      let layout = PDFSpine.layout(block, at:position, in:trim),
                      layout.overflow.width <= 0.00001, layout.overflow.height <= 0.00001 else { continue }
                context.saveGState()
                context.concatenate(layout.transform)
                context.setFillColor(PDFSpine.color(block.color))
                if block.outlines {
                    context.addPath(layout.path)
                    context.fillPath()
                } else {
                    context.textMatrix = .identity
                    context.textPosition = .zero
                    CTLineDraw(layout.line,context)
                }
                context.restoreGState()
            }
        }
    }

    private func extendVector(_ page: CGPDFPage,edge: SampleEdge,strip: EdgeStrip,x: Double,width: Double,
                              trim: CGRect,clip: CGRect,in context: CGContext) {
        let box = page.getBoxRect(.trimBox).intersection(page.getBoxRect(.mediaBox))
        let rotated = page.rotationAngle % 180 != 0
        let source = CGRect(x:0,y:0,width:(rotated ? box.height : box.width)/PDFPreviewDrawing.pointsPerMM,
                            height:(rotated ? box.width : box.height)/PDFPreviewDrawing.pointsPerMM)
        let depth = min(source.width,0.05)
        guard depth > 0, source.height > 0 else { return }
        let scale = width/depth
        let start = edge == .right ? source.maxX-depth : source.minX
        let band = CGRect(x:x,y:trim.minY,width:width,height:trim.height)
        context.setFillColor(PDFSpine.color(strip.firstColor))
        context.fill(CGRect(x:x,y:trim.maxY,width:width,height:max(0,clip.maxY-trim.maxY)))
        context.setFillColor(PDFSpine.color(strip.lastColor))
        context.fill(CGRect(x:x,y:clip.minY,width:width,height:max(0,trim.minY-clip.minY)))
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to:band)
        context.translateBy(x:x,y:trim.minY)
        context.scaleBy(x:scale,y:trim.height/source.height)
        context.translateBy(x:-start,y:0)
        PDFPreviewDrawing.draw(page,in:context,rect:source)
    }
}
