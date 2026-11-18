import Foundation
import CoreGraphics
import ImpositionCore

/// Immutable render variants for a plan. Each variant uses copy-on-write PDF
/// resources, so different jobs can apply different values to the same page.
public final class PDFColorVariants: @unchecked Sendable {
    private struct Variant {
        let document: CGPDFDocument
        let samples = PDFEdgeSampleCache()
    }

    private let variants: [ImageColorAdjustment: Variant]
    public let warnings: [String]

    private init(variants: [ImageColorAdjustment: Variant] = [:], warnings: [String] = []) {
        self.variants = variants
        self.warnings = warnings
    }

    public static func requests(in plan: ImpositionPlan) -> [ImageColorAdjustment: Set<Int>] {
        var requests: [ImageColorAdjustment: Set<Int>] = [:]
        for sheet in plan.sheets {
            for slot in sheet.front.slots + sheet.back.slots {
                guard let page = slot.sourcePageNumber, let adjustment = slot.imageColor, !adjustment.isNeutral else { continue }
                requests[adjustment, default: []].insert(page)
            }
        }
        return requests
    }

    public static func prepare(source: PDFSource, plan: ImpositionPlan) throws -> PDFColorVariants {
        let requests = requests(in: plan)
        guard !requests.isEmpty else { return PDFColorVariants() }
        let unsupported = "Bu PDF’nin nesne yapısı güvenli renk düzenlemesini desteklemiyor. Görseller özgün renkleriyle kullanıldı."
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path),
              let length = attributes[.size] as? NSNumber, length.intValue < 64 * 1024 * 1024,
              let data = try? Data(contentsOf: source.url), let file = try? PDFClassicFile(data),
              let document = CGPDFDocument(source.url as CFURL), document.numberOfPages == file.pages.count else {
            return PDFColorVariants(warnings: [unsupported])
        }
        let editor = PDFImageColorEditor(file: file, document: document)
        var variants: [ImageColorAdjustment: Variant] = [:]
        var totalBytes = 0
        var warnings = Set<String>()
        let ordered = requests.keys.sorted {
            [$0.brightness, $0.contrast, $0.saturation].lexicographicallyPrecedes([$1.brightness, $1.contrast, $1.saturation])
        }
        for adjustment in ordered {
            try Task.checkCancellation()
            do {
                let (data, notes) = try editor.variant(pages: requests[adjustment] ?? [], adjustment: adjustment)
                warnings.formUnion(notes)
                guard let data else { continue }
                guard totalBytes + data.count <= 256 * 1024 * 1024 else {
                    warnings.insert("Renk düzenleme bellek sınırını aşan işler özgün renkleriyle kullanıldı.")
                    continue
                }
                guard let provider = CGDataProvider(data: data as CFData),
                      let changed = CGPDFDocument(provider), changed.numberOfPages == document.numberOfPages else {
                    warnings.insert(unsupported)
                    continue
                }
                variants[adjustment] = Variant(document: changed)
                totalBytes += data.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.insert(unsupported)
            }
        }
        return PDFColorVariants(variants: variants, warnings: warnings.sorted())
    }

    public func page(for slot: Slot) -> CGPDFPage? {
        guard let adjustment = slot.imageColor, let number = slot.sourcePageNumber else { return nil }
        return variants[adjustment]?.document.page(at: number)
    }

    public func edgeSamples(for slot: Slot) -> PDFEdgeSampleCache? {
        slot.imageColor.flatMap { variants[$0]?.samples }
    }
}
