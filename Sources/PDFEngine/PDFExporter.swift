import Foundation
import CoreGraphics
import ImpositionCore

public enum PDFExportDestination: Sendable {
    case singlePDF(URL)
    case perSheet(directory: URL,baseName: String)
    var scopeURL: URL {
        switch self { case .singlePDF(let url): return url; case .perSheet(let url,_): return url }
    }
}
public struct PDFExportResult: Sendable {
    public let files: [URL]
    public let pageCount: Int
    public let sheetCount: Int
}
public enum PDFExportError: LocalizedError {
    case invalidPlan, invalidGeometry, missingPage(Int), cannotCreatePDF, sourceOverwrite, destinationExists(String), tooManyPages
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: return "Plan dışa aktarılamıyor. Önce doğrulama hatalarını giderin."
        case .invalidGeometry: return "Planda geçersiz bir ölçü veya dönüşüm var."
        case .missingPage(let number): return "Kaynak PDF içinde sayfa \(number) bulunamadı."
        case .cannotCreatePDF: return "PDF çıktısı oluşturulamadı."
        case .sourceOverwrite: return "Kaynak PDF dosyasının üzerine yazılamaz. Farklı bir ad seçin."
        case .destinationExists(let name): return "Çıktı zaten var: \(name). Boş bir klasör seçin."
        case .tooManyPages: return "Toplam PDF sayfa sayısı bu sistemin tam sayı kapasitesini aşıyor."
        }
    }
}

public enum PDFExporter {
    public static let maximumPageCount = Int.max
    /// Call off the main actor. Source/plan/options are an immutable export snapshot.
    /// Physical repeats are expanded, in sheet-front/back order, without rasterizing artwork.
    /// Compatibility entry point: preview styles are never used in production.
    public static func export(plan: ImpositionPlan,source: PDFSource,destination: PDFExportDestination,
                              options: PDFRenderOptions,overlays: [any PDFSlotOverlay] = []) throws -> PDFExportResult {
        var marks = ExportMarks.none
        marks.crop = options.crop; marks.fold = options.fold; marks.bleed = options.bleed
        marks.safeArea = options.safeArea; marks.pageNumbers = options.pageNumbers
        return try export(plan: plan,source: source,destination: destination,marks: marks,overlays: overlays)
    }
    public static func export(plan: ImpositionPlan,source: PDFSource,destination: PDFExportDestination,
                              marks: ExportMarks = ExportMarks(),jobName: String = "",overlays: [any PDFSlotOverlay] = []) throws -> PDFExportResult {
        guard plan.canExport, plan.diagnosticSheets.isEmpty, plan.generatedBleed.isValid, !plan.sheets.isEmpty else { throw PDFExportError.invalidPlan }
        var sheetCount = 0
        for sheet in plan.sheets {
            guard sheet.repeatCount > 0, sheet.repeatCount <= maximumPageCount/2-sheetCount else { throw PDFExportError.tooManyPages }
            sheetCount += sheet.repeatCount
            try validate(sheet)
        }
        guard let document = CGPDFDocument(source.url as CFURL) else { throw PDFReadError.unreadable }
        if !document.isUnlocked && !document.unlockWithPassword("") { throw PDFReadError.locked }
        for sheet in plan.sheets {
            for slot in sheet.front.slots+sheet.back.slots {
                if let number = slot.sourcePageNumber, number < 1 || number > document.numberOfPages { throw PDFExportError.missingPage(number) }
            }
        }
        let generated: [any PDFSlotOverlay] = plan.generatedBleed.enabled ?
            [GeneratedBleedOverlay(settings: plan.generatedBleed,cache: source.edgeSamples,sampleIfMissing: true)] : []
        let effectiveOverlays = generated+overlays
        let scope = destination.scopeURL
        let accessed = scope.startAccessingSecurityScopedResource()
        defer { if accessed { scope.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let directory: URL
        let outputCount: Int
        switch destination {
        case .singlePDF(let url): directory = url.deletingLastPathComponent(); outputCount = 1
        case .perSheet(let folder,_): directory = folder; outputCount = sheetCount
        }
        func target(_ index: Int) -> URL {
            switch destination {
            case .singlePDF(let url): return url
            case .perSheet(let folder,let base):
                return folder.appendingPathComponent(String(format: "%@-tabaka-%04lld.pdf",sanitized(base),Int64(index+1)))
            }
        }
        // Check destinations without allocating a quantity-sized array of paths.
        for index in 0..<outputCount {
            try Task.checkCancellation()
            let file = target(index)
            guard file.standardizedFileURL.resolvingSymlinksInPath() != source.url.standardizedFileURL.resolvingSymlinksInPath() else {
                throw PDFExportError.sourceOverwrite
            }
            if case .perSheet = destination,manager.fileExists(atPath: file.path) {
                throw PDFExportError.destinationExists(file.lastPathComponent)
            }
        }
        let stage = directory.appendingPathComponent(".atispress-\(UUID().uuidString)",isDirectory: true)
        try manager.createDirectory(at: stage,withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        func stagedFile(_ index: Int) -> URL {
            switch destination {
            case .singlePDF: return stage.appendingPathComponent("job.pdf")
            case .perSheet: return stage.appendingPathComponent(target(index).lastPathComponent)
            }
        }
        switch destination {
        case .singlePDF:
            try write(stagedFile(0),document: document,plan: plan,marks: marks,jobName: jobName,overlays: effectiveOverlays,only: nil)
        case .perSheet:
            var physical = 0
            for (index,sheet) in plan.sheets.enumerated() {
                for repetition in 0..<sheet.repeatCount {
                    try Task.checkCancellation()
                    try write(stagedFile(physical),document: document,plan: plan,marks: marks,jobName: jobName,overlays: effectiveOverlays,only: (index,repetition))
                    physical += 1
                }
            }
        }
        try Task.checkCancellation()
        // Publish only complete PDFs. Per-sheet files never replace existing files.
        var published: [URL] = []
        do {
            for index in 0..<outputCount {
                try Task.checkCancellation()
                let temporary = stagedFile(index),file = target(index)
                if case .singlePDF = destination,manager.fileExists(atPath: file.path) {
                    _ = try manager.replaceItemAt(file,withItemAt: temporary)
                } else { try manager.moveItem(at: temporary,to: file) }
                published.append(file)
            }
        } catch {
            if case .perSheet = destination { for file in published { try? manager.removeItem(at: file) } }
            throw error
        }
        return PDFExportResult(files: published,pageCount: sheetCount*2,sheetCount: sheetCount)
    }
    private static func write(_ url: URL,document: CGPDFDocument,plan: ImpositionPlan,marks: ExportMarks,jobName: String,
                              overlays: [any PDFSlotOverlay],only: (Int,Int)?) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer,mediaBox: nil,[kCGPDFContextCreator:"AtışPress"] as CFDictionary) else {
            throw PDFExportError.cannotCreatePDF
        }
        defer { context.closePDF() }
        let indices = only.map { $0.0..<($0.0+1) } ?? plan.sheets.indices
        for index in indices {
            let sheet = plan.sheets[index]
            let repetitions = only.map { $0.1..<($0.1+1) } ?? 0..<sheet.repeatCount
            for repetition in repetitions {
                for (kind,side) in [(SideKind.front,sheet.front),(.back,sheet.back)] {
                    try Task.checkCancellation()
                    var media = CGRect(x: 0,y: 0,width: sheet.size.width*PDFPreviewDrawing.pointsPerMM,
                                       height: sheet.size.height*PDFPreviewDrawing.pointsPerMM)
                    let box = NSData(bytes: &media,length: MemoryLayout<CGRect>.size)
                    context.beginPDFPage([kCGPDFContextMediaBox:box] as CFDictionary)
                    do {
                        context.saveGState()
                        context.scaleBy(x: PDFPreviewDrawing.pointsPerMM,y: PDFPreviewDrawing.pointsPerMM)
                        context.clip(to: CGRect(x: 0,y: 0,width: sheet.size.width,height: sheet.size.height))
                        try PDFPlanRenderer.drawSide(side,sheet: sheet,document: document,in: context,sheetIndex: index,
                                                     kind: kind,repetition: repetition,options: .artworkOnly,overlays: overlays)
                        PDFExportMarkRenderer.draw(side: side,sheet: sheet,in: context,settings: marks,
                            info: "\(jobName) · Tabaka \(plan.sheets.prefix(index).reduce(0) { $0+$1.repeatCount }+repetition+1) · \(kind == .front ? "Ön" : "Arka")")
                        context.restoreGState(); context.endPDFPage()
                    } catch {
                        context.restoreGState(); context.endPDFPage(); throw error
                    }
                }
            }
        }
    }
    private static func validate(_ sheet: Sheet) throws {
        guard sheet.diagnosticBounds == nil,sheet.size.width.isFinite,sheet.size.height.isFinite,sheet.size.width > 0,sheet.size.height > 0 else {
            throw PDFExportError.invalidGeometry
        }
        if let serials = sheet.serialPlan {
            guard serials.quantity > 0,(1...20_000).contains(serials.capacity),
                  serials.sheetCount == sheet.repeatCount,serials.fields.count <= 100,
                  serials.fields.allSatisfy({ $0.isValid && $0.value(at: serials.quantity-1) != nil }) else {
                throw PDFExportError.invalidGeometry
            }
        }
        for side in [sheet.front,sheet.back] {
            for slot in side.slots {
                guard [slot.x,slot.y,slot.size.width,slot.size.height].allSatisfy(\.isFinite),
                      slot.size.width > 0,slot.size.height > 0,slot.rotation%90 == 0 else { throw PDFExportError.invalidGeometry }
                if let clip = slot.artworkClip {
                    guard [clip.origin.x,clip.origin.y,clip.size.width,clip.size.height].allSatisfy(\.isFinite),
                          clip.size.width > 0,clip.size.height > 0 else { throw PDFExportError.invalidGeometry }
                }
            }
            for mark in side.marks {
                guard [mark.start.x,mark.start.y,mark.end.x,mark.end.y].allSatisfy(\.isFinite) else { throw PDFExportError.invalidGeometry }
            }
        }
    }
    private static func sanitized(_ name: String) -> String {
        let result = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined().prefix(100))
        return result.isEmpty ? "AtisPress" : result
    }
}
