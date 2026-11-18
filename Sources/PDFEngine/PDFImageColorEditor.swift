import Foundation
import CoreGraphics
import ImpositionCore
import zlib

/// Keeps the original page content, resource references and color profiles.
struct PDFImageColorEditor {
    let file: PDFClassicFile
    let document: CGPDFDocument

    private func resolved(_ key: String, in dictionary: Data) throws -> Data? {
        guard let tokens = file.value(key, pdfTokens(dictionary)), let first = tokens.first, let last = tokens.last else { return nil }
        if tokens.count == 3, last.text == "R", let id = Int(first.text),
           let generation = Int(tokens[1].text), file.offsets[id]?.1 == generation {
            return try file.dictionary(id, maximumBytes: 256 * 1024)
        }
        guard first.text == "<<", last.text == ">>" else { throw SourcePreparationError.unsafeGuides }
        return dictionary.subdata(in: first.range.lowerBound..<last.range.upperBound)
    }

    private func set(_ key: String, to replacement: Data?, in dictionary: inout Data) {
        let tokens = pdfTokens(dictionary)
        if let value = file.value(key, tokens), let first = value.first, let last = value.last {
            if let replacement { dictionary.replaceSubrange(first.range.lowerBound..<last.range.upperBound, with: replacement) }
            else if let index = tokens.firstIndex(where: { $0.range == first.range }), index > 0 {
                dictionary.removeSubrange(tokens[index - 1].range.lowerBound..<last.range.upperBound)
            }
        } else if let replacement {
            var entry = Data(" \(key) ".utf8)
            entry.append(replacement)
            entry.append(32)
            dictionary.insert(contentsOf: entry, at: dictionary.count - 2)
        }
    }

    private func resources(for pageDictionary: Data) throws -> Data? {
        var current = pageDictionary
        for _ in 0..<32 {
            if let result = try resolved("/Resources", in: current) { return result }
            guard let parent = file.reference("/Parent", current) else { return nil }
            current = try file.dictionary(parent, maximumBytes: 256 * 1024)
        }
        throw SourcePreparationError.unsafeGuides
    }

    private struct Target {
        let name: String
        let id: Int
        let dictionary: Data
        let dictionaryEnd: Int
        let stream: CGPDFStreamRef
        let live: CGPDFDictionaryRef
        let form: Scope?
    }

    private struct Scope {
        let content: Data
        let uses: [PDFContentToken]
        let resources: Data
        let objects: Data
        let live: CGPDFDictionaryRef
        let targets: [Target]
        let path: String
    }

    private struct Budget {
        var visits = 4096
        var bytes = 32 * 1024 * 1024

        mutating func consume(_ count: Int) -> Bool {
            guard count <= bytes else { return false }
            bytes -= count
            return true
        }
    }

    private func scope(content: Data, resources: Data?, live: CGPDFDictionaryRef?, group: Bool,
                       path: String, ancestors: Set<Int>, budget: inout Budget,
                       warnings: inout Set<String>) throws -> (Scope?, Bool) {
        guard content.count <= 4 * 1024 * 1024, budget.consume(content.count) else {
            warnings.insert("\(path): İçerik akışı inceleme sınırını aşıyor.")
            return (nil, false)
        }
        let tokens = pdfTokens(content)
        guard tokens.last?.text != "BI" else {
            warnings.insert("\(path): Satır içi görsel (BI) bulundu. Bu içerik akışı özgün haliyle kullanıldı.")
            return (nil, false)
        }
        var uses: [PDFContentToken] = []
        var depth = 0
        for index in tokens.indices {
            switch tokens[index].text {
            case "<<", "[": depth += 1
            case ">>", "]": depth -= 1
            case "Do" where depth == 0 && index > 0 && tokens[index - 1].text.hasPrefix("/"):
                uses.append(tokens[index - 1])
            default: break
            }
        }
        var safe = !group && Self.allowsCMYKAdjustment(tokens: tokens, resources: live)
        let names = Set(uses.map(\.text))
        guard !names.isEmpty else { return (nil, safe) }
        guard let resources, let objects = try? resolved("/XObject", in: resources),
              let live, let liveObjects = Self.dictionary("XObject", in: live) else {
            warnings.insert("\(path): /Resources veya /XObject sözlüğü çözümlenemedi.")
            return (nil, false)
        }
        guard budget.consume(resources.count + objects.count) else {
            warnings.insert("\(path): Kaynak sözlükleri toplam inceleme sınırını aşıyor.")
            return (nil, false)
        }
        let objectTokens = pdfTokens(objects)
        var targets: [Target] = []
        for name in names.sorted() {
            try Task.checkCancellation()
            let location = "\(path) \(name)"
            guard budget.visits > 0 else {
                warnings.insert("PDF nesne inceleme sınırına ulaşıldı. Kalan nesneler özgün haliyle kullanıldı.")
                safe = false
                break
            }
            budget.visits -= 1
            guard !name.contains("#") else {
                warnings.insert("\(location): Kaçış kodlu kaynak adı desteklenmiyor.")
                safe = false
                continue
            }
            var stream: CGPDFStreamRef?
            guard let reference = file.value(name, objectTokens), reference.count == 3,
                  reference.last?.text == "R", let id = Int(reference[0].text),
                  let generation = Int(reference[1].text), file.offsets[id]?.1 == generation,
                  let objectDictionary = try? file.objectDictionary(id),
                  CGPDFDictionaryGetStream(liveObjects, String(name.dropFirst()), &stream),
                  let stream, let object = CGPDFStreamGetDictionary(stream) else {
                warnings.insert("\(location): XObject akış başvurusu çözümlenemedi.")
                safe = false
                continue
            }
            let dictionary = objectDictionary.bytes
            guard budget.consume(dictionary.count) else {
                warnings.insert("\(location): Nesne sözlüğü toplam inceleme sınırını aşıyor.")
                safe = false
                break
            }
            let subtype = Self.name("Subtype", in: object)
            var child: Scope?
            switch subtype {
            case "Image":
                if !ancestors.isEmpty, let colorName = Self.name("ColorSpace", in: object),
                   !["DeviceGray", "DeviceRGB", "DeviceCMYK"].contains(colorName) {
                    // Quartz can silently fail to draw a Form image whose
                    // ColorSpace depends on a named resource.
                    warnings.insert("\(location): Form görselinde adlandırılmış /ColorSpace /\(colorName) güvenli biçimde görüntülenemiyor.")
                    safe = false
                    continue
                }
                safe = safe && Self.colorSpace(object, resources: live) != nil
            case "Form":
                guard ancestors.count < 8, !ancestors.contains(id) else {
                    let reason = ancestors.contains(id) ? "Form döngüsü bulundu." : "8 düzeylik iç içe Form sınırı aşıldı."
                    warnings.insert("\(location): \(reason)")
                    safe = false
                    continue
                }
                let formTokens = pdfTokens(dictionary)
                let specialKeys = ["/F", "/FFilter", "/FDecodeParms", "/Ref", "/PS"]
                let unsupportedKeys = specialKeys.filter { file.value($0, formTokens) != nil }
                guard unsupportedKeys.isEmpty else {
                    warnings.insert("\(location): Dış kaynak veya PostScript kullanan Form desteklenmiyor (\(unsupportedKeys.joined(separator: ", "))).")
                    safe = false
                    continue
                }
                guard let formResources = try? resolved("/Resources", in: dictionary),
                      let liveFormResources = Self.dictionary("Resources", in: object) else {
                    warnings.insert("\(location): Formun kendi /Resources sözlüğü yok veya okunamıyor.")
                    safe = false
                    continue
                }
                var format = CGPDFDataFormat.raw
                guard let bytes = CGPDFStreamCopyData(stream, &format), format == .raw else {
                    warnings.insert("\(location): Form içerik akışı çözümlenemedi.")
                    safe = false
                    continue
                }
                let nested = try scope(content: bytes as Data, resources: formResources, live: liveFormResources,
                                       group: file.value("/Group", formTokens) != nil, path: location,
                                       ancestors: ancestors.union([id]), budget: &budget, warnings: &warnings)
                safe = safe && nested.1
                guard let nestedScope = nested.0 else { continue }
                child = nestedScope
            default:
                warnings.insert("\(location): XObject türü desteklenmiyor (\(subtype ?? "Subtype yok")).")
                safe = false
                continue
            }
            targets.append(Target(name: name, id: id, dictionary: dictionary, dictionaryEnd: objectDictionary.end, stream: stream, live: object, form: child))
        }
        return (Scope(content: content, uses: uses, resources: resources, objects: objects,
                      live: live, targets: targets, path: path), safe)
    }

    func variant(pages: Set<Int>, adjustment: ImageColorAdjustment) throws -> (Data?, [String]) {
        let result = try process(pages: pages, adjustment: adjustment, inspect: false)
        return (result.0, result.1.warnings)
    }

    func inspect(pages: Set<Int>) throws -> PDFColorInspection {
        // The same decode and ICC round trip checks also run before sliders are enabled.
        var probe = ImageColorAdjustment()
        probe.contrast = 0
        return try process(pages: pages, adjustment: probe, inspect: true).1
    }

    private func process(pages: Set<Int>, adjustment: ImageColorAdjustment, inspect: Bool)
        throws -> (Data?, PDFColorInspection) {
        guard adjustment.isValid else {
            return (nil, PDFColorInspection(warnings: ["Renk değerleri geçersiz."]))
        }
        var output = Data()
        output.append(10)
        var entries: [Int: (Int, Int)] = [:]
        var next = (file.offsets.keys.max() ?? 0) + 1
        var warnings = Set<String>()
        var editable: [Int: Int] = [:]
        var budget = Budget()
        var sampleBudget = 96 * 1024 * 1024
        var changedPages = 0

        func append(dictionary: Data, stream: Data? = nil, existingID: Int? = nil) -> Int? {
            guard output.count + dictionary.count + (stream?.count ?? 0) <= 96 * 1024 * 1024 else {
                warnings.insert("Renk varyantının artımlı güncelleme sınırı (96 MiB) aşıldı. Sınıra takılan nesneler özgün haliyle kullanıldı.")
                return nil
            }
            let id = existingID ?? next
            if existingID == nil { next += 1 }
            let generation = existingID.flatMap { file.offsets[$0]?.1 } ?? 0
            entries[id] = (file.source.count + output.count, generation)
            output.append(Data("\(id) \(generation) obj\n".utf8))
            output.append(dictionary)
            if let stream {
                output.append(Data("\nstream\n".utf8))
                output.append(stream)
                output.append(Data("\nendstream".utf8))
            }
            output.append(Data("\nendobj\n".utf8))
            return id
        }

        // Rewrite only Do operands in copied scopes. The original objects can
        // also be used by masks, patterns, annotations or other pages.
        func rewrite(_ scope: Scope, allowsCMYK: Bool) throws -> (Data, Data)? {
            var objects = scope.objects
            var resources = scope.resources
            var aliases: [String: String] = [:]
            var replacements: [Int: Int] = [:]
            var attempted = Set<Int>()
            for target in scope.targets {
                try Task.checkCancellation()
                let location = "\(scope.path) \(target.name)"
                var replacement = replacements[target.id]
                if attempted.insert(target.id).inserted {
                    var dictionary = target.dictionary
                    if let form = target.form {
                        if let (content, formResources) = try rewrite(form, allowsCMYK: allowsCMYK) {
                            set("/Resources", to: formResources, in: &dictionary)
                            set("/Length", to: Data(String(content.count).utf8), in: &dictionary)
                            set("/Filter", to: nil, in: &dictionary)
                            set("/DecodeParms", to: nil, in: &dictionary)
                            replacement = append(dictionary: dictionary, stream: content)
                        }
                    } else {
                        var notes = Set<String>()
                        var components: Int?
                        let bytes = try adjusted(target.stream, dictionary: target.live, resources: scope.live,
                                                 dictionaryEnd: target.dictionaryEnd, adjustment: adjustment,
                                                 allowsCMYK: allowsCMYK, inspect: inspect,
                                                 sampleBudget: &sampleBudget, components: &components, warnings: &notes)
                        warnings.formUnion(notes.map { "\(location): \($0)" })
                        if let components { editable[target.id] = components }
                        if let bytes {
                            set("/Length", to: Data(String(bytes.count).utf8), in: &dictionary)
                            set("/Filter", to: Data("/FlateDecode".utf8), in: &dictionary)
                            set("/DecodeParms", to: nil, in: &dictionary)
                            replacement = append(dictionary: dictionary, stream: bytes)
                        }
                    }
                    replacements[target.id] = replacement
                }
                guard let replacement else { continue }
                var alias = "/AtisPressColor\(replacement)"
                while file.value(alias, pdfTokens(objects)) != nil { alias += "_" }
                set(alias, to: Data("\(replacement) 0 R".utf8), in: &objects)
                aliases[target.name] = alias
            }
            guard !aliases.isEmpty else { return nil }
            var content = scope.content
            for use in scope.uses.reversed() {
                if let alias = aliases[use.text] { content.replaceSubrange(use.range, with: Data(alias.utf8)) }
            }
            set("/XObject", to: objects, in: &resources)
            return (content, resources)
        }

        for number in pages.sorted() {
            try Task.checkCancellation()
            let path = "Sayfa \(number)"
            guard number > 0, file.pages.indices.contains(number - 1),
                  let page = document.page(at: number),
                  let content = pdfPageContent(page) else {
                warnings.insert("\(path): Sayfa veya /Contents akışı okunamadı.")
                continue
            }
            let pageID = file.pages[number - 1]
            guard var dictionary = try? file.dictionary(pageID, maximumBytes: 256 * 1024) else {
                warnings.insert("\(path): Sayfa sözlüğü okunamadı.")
                continue
            }
            let (pageScope, safeCMYK) = try scope(content: content, resources: try? resources(for: dictionary),
                                                  live: Self.liveResources(page),
                                                  group: file.value("/Group", pdfTokens(dictionary)) != nil,
                                                  path: path, ancestors: [], budget: &budget, warnings: &warnings)
            guard let pageScope, let (revised, resources) = try rewrite(pageScope, allowsCMYK: safeCMYK),
                  let streamID = append(dictionary: Data("<< /Length \(revised.count) >>".utf8), stream: revised) else { continue }
            set("/Contents", to: Data("\(streamID) 0 R".utf8), in: &dictionary)
            set("/Resources", to: resources, in: &dictionary)
            if append(dictionary: dictionary, existingID: pageID) != nil { changedPages += 1 }
        }
        if editable.isEmpty {
            warnings.insert("Seçili sayfalarda renk düzenlemesine uygun görsel bulunamadı.")
        }
        let result = PDFColorInspection(editableCount: editable.count,
                                        saturationCount: editable.values.filter { $0 > 1 }.count,
                                        warnings: warnings.sorted())
        guard changedPages > 0 else { return (nil, result) }
        let xref = file.source.count + output.count
        guard xref <= 9_999_999_999 else {
            warnings.insert(PDFClassicFile.StructureError.offsetLimit.rawValue)
            return (nil, PDFColorInspection(warnings: warnings.sorted()))
        }
        output.append(file.incrementalXref(at: xref, entries: entries, size: next))
        return (output, result)
    }

    private func adjusted(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, resources: CGPDFDictionaryRef,
                          dictionaryEnd: Int, adjustment: ImageColorAdjustment, allowsCMYK: Bool, inspect: Bool,
                          sampleBudget: inout Int, components eligible: inout Int?, warnings: inout Set<String>) throws -> Data? {
        guard let colorSpace = Self.colorSpace(dictionary, resources: resources) else {
            warnings.insert("CMYK, spot ve desteklenmeyen renk uzayları özgün renkleriyle kullanıldı.")
            return nil
        }
        let components = colorSpace.components
        if components == 4 {
            guard colorSpace.profile != nil else {
                warnings.insert("Gömülü baskı ICC profili olmayan CMYK görseller özgün renkleriyle kullanıldı.")
                return nil
            }
            if let intent = Self.name("Intent", in: dictionary), intent != "RelativeColorimetric" {
                warnings.insert("Özel renk dönüşüm amacı olan CMYK görseller özgün renkleriyle kullanıldı.")
                return nil
            }
            guard allowsCMYK else {
                warnings.insert("Spot renk, üst baskı veya birleşik grafik durumu içerebilen sayfalardaki CMYK görseller özgün renkleriyle kullanıldı.")
                return nil
            }
        }
        if components == 1 && adjustment.saturation != 1 {
            warnings.insert("Doygunluk gri tonlamalı görsellere uygulanmadı.")
        }
        let excluded = ["SMask", "Mask", "ImageMask", "SMaskInData", "Decode", "F", "FFilter", "FDecodeParms", "Alternates"]
        let unsupportedKeys = excluded.filter { key in
            var object: CGPDFObjectRef?
            return CGPDFDictionaryGetObject(dictionary, key, &object)
        }
        guard unsupportedKeys.isEmpty else {
            let keys = unsupportedKeys.map { "/" + $0 }.joined(separator: ", ")
            warnings.insert("Maskeli, özel kod çözmeli veya dış kaynaklı görsel (\(keys)) özgün renkleriyle kullanıldı.")
            return nil
        }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits), bits == 8 else {
            warnings.insert("Görselin /BitsPerComponent değeri 8 değil veya eksik.")
            return nil
        }
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0 else {
            warnings.insert("Görselin /Width veya /Height değeri geçersiz.")
            return nil
        }
        guard width <= 12_000_000 / height / components else {
            warnings.insert("Görselin açılmış örnek verisi 12.000.000 bayt sınırını aşıyor.")
            return nil
        }
        let sampleCount = width * height * components
        guard sampleCount <= sampleBudget else {
            warnings.insert("Görsel örnekleri toplam inceleme sınırını (96 MiB) aşıyor.")
            return nil
        }
        sampleBudget -= sampleCount
        let filter = Self.name("Filter", in: dictionary)
        var filterObject: CGPDFObjectRef?
        let hasFilter = CGPDFDictionaryGetObject(dictionary, "Filter", &filterObject)
        var filterArray: CGPDFArrayRef?, dct: UnsafePointer<CChar>?
        let arrayDCT = CGPDFDictionaryGetArray(dictionary, "Filter", &filterArray) &&
            filterArray.map { CGPDFArrayGetCount($0) == 1 && CGPDFArrayGetName($0, 0, &dct) } == true &&
            dct.map { String(cString: $0) == "DCTDecode" } == true
        if components == 4 && hasFilter && filter != "FlateDecode" {
            warnings.insert("Yalnız ham veya Flate sıkıştırmalı CMYK görseller düzenlenebilir. Diğer CMYK görseller özgün renkleriyle kullanıldı.")
            return nil
        }
        let jpeg = filter == "DCTDecode" || arrayDCT
        guard jpeg || !hasFilter || filter == "FlateDecode" else {
            warnings.insert("JPEG 2000, çoklu filtreli veya desteklenmeyen sıkıştırmalı görseller özgün renkleriyle kullanıldı.")
            return nil
        }
        var length: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Length", &length), length > 0 else {
            warnings.insert("Görsel akışının /Length değeri eksik veya geçersiz.")
            return nil
        }
        guard length <= 16 * 1024 * 1024 else {
            warnings.insert("Görselin kodlanmış akışı 16 MiB sınırını aşıyor.")
            return nil
        }
        var data: Data
        if jpeg {
            guard Self.supportsDCTParameters(dictionary, components: components),
                  let encoded = encodedStream(after: dictionaryEnd, length: length),
                  let samples = try PDFJPEGImageSamples.decode(encoded, width: width, height: height,
                                                                components: components, pdfICC: colorSpace.profile) else {
                warnings.insert("Desteklenmeyen, bozuk veya ICC profili uyuşmayan JPEG görseller özgün renkleriyle kullanıldı.")
                return nil
            }
            data = samples
        } else if filter == "FlateDecode" {
            guard let encoded = encodedStream(after: dictionaryEnd, length: length) else {
                warnings.insert("Flate görselinin akış sınırları /Length ile eşleşmiyor.")
                return nil
            }
            guard let predictor = Self.flatePredictor(dictionary, width: width, components: components) else {
                warnings.insert("Flate görselinin /DecodeParms değerleri görsel boyutlarıyla uyumlu değil.")
                return nil
            }
            let count = sampleCount + (predictor >= 10 ? height : 0)
            guard let decoded = Self.inflate(encoded, count: count) else {
                warnings.insert("Flate görselinin açılmış akışı örnek boyutunu aşıyor veya sıkıştırma verisi bozuk.")
                return nil
            }
            if predictor == 1 {
                data = decoded
            } else {
                var format = CGPDFDataFormat.raw
                guard let bytes = CGPDFStreamCopyData(stream, &format), format == .raw,
                      CFDataGetLength(bytes) == sampleCount else {
                    warnings.insert("Flate görselinin predictor verisi çözümlenemedi.")
                    return nil
                }
                data = bytes as Data
            }
        } else {
            guard length == sampleCount, let bytes = encodedStream(after: dictionaryEnd, length: length) else {
                warnings.insert("Ham görselin /Length değeri beklenen örnek boyutuyla eşleşmiyor.")
                return nil
            }
            data = bytes
        }
        if components == 4, let profile = colorSpace.profile {
            guard let edited = try PDFCMYKImageColor.adjust(data, width: width, height: height, profile: profile, editRGB: { rgb in
                try Self.applyAdjustment(adjustment, to: &rgb, components: 3)
            }) else {
                warnings.insert("ICC profili doğrulanamayan veya çift yönlü dönüşümü olmayan CMYK görseller özgün renkleriyle kullanıldı.")
                return nil
            }
            eligible = components
            guard !inspect, edited != data else { return nil }
            data = edited
            warnings.insert("CMYK görseller kendi ICC profillerine geri dönüştürüldü. Düzenlenen piksellerde mürekkep oranları değişebilir.")
        } else {
            eligible = components
            guard !inspect else { return nil }
            if components == 1 && adjustment.brightness == 0 && adjustment.contrast == 1 { return nil }
            try Self.applyAdjustment(adjustment, to: &data, components: components)
        }
        var capacity = compressBound(uLong(data.count))
        var compressed = Data(count: Int(capacity))
        let status = compressed.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compress2(target.bindMemory(to: Bytef.self).baseAddress, &capacity,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { return nil }
        compressed.count = Int(capacity)
        return compressed
    }

    private func encodedStream(after dictionaryEnd: Int, length: Int) -> Data? {
        let source = file.source
        let prefix = source.read(dictionaryEnd..<min(dictionaryEnd + 1024, source.count))
        let white: Set<UInt8> = [0, 9, 10, 12, 13, 32]
        var start = 0
        while start < prefix.count {
            if white.contains(prefix[start]) { start += 1 }
            else if prefix[start] == 37 {
                while start < prefix.count, prefix[start] != 10, prefix[start] != 13 { start += 1 }
            } else { break }
        }
        guard prefix.dropFirst(start).starts(with: "stream".utf8) else { return nil }
        var begin = start + 6
        while begin < prefix.count, prefix[begin] == 32 || prefix[begin] == 9 { begin += 1 }
        if begin < prefix.count, prefix[begin] == 13 { begin += 1 }
        guard begin < prefix.count, prefix[begin] == 10 else { return nil }
        let payload = dictionaryEnd + begin + 1
        let end = payload + length
        guard end <= source.count else { return nil }
        let terminator = source.read(end..<min(end + 32, source.count))
        guard terminator.drop(while: { white.contains($0) }).starts(with: "endstream".utf8) else { return nil }
        let bytes = source.read(payload..<end)
        return bytes.count == length ? bytes : nil
    }

    private static func flatePredictor(_ image: CGPDFDictionaryRef, width: Int, components: Int) -> Int? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(image, "DecodeParms", &object), let object,
              CGPDFObjectGetType(object) != .null else { return 1 }
        guard let parameters = dictionary("DecodeParms", in: image) else { return nil }
        func integer(_ name: String, default fallback: Int) -> Int {
            var value: CGPDFInteger = 0
            return CGPDFDictionaryGetInteger(parameters, name, &value) ? value : fallback
        }
        let predictor = integer("Predictor", default: 1)
        if predictor == 1 { return 1 }
        guard predictor == 2 || (10...15).contains(predictor),
              integer("Columns", default: 1) == width,
              integer("Colors", default: 1) == components,
              integer("BitsPerComponent", default: 8) == 8 else { return nil }
        return predictor
    }

    private static func inflate(_ encoded: Data, count: Int) -> Data? {
        var decoded = Data(count: count)
        var length = uLongf(count)
        let status = decoded.withUnsafeMutableBytes { output in
            encoded.withUnsafeBytes { input in
                uncompress(output.bindMemory(to: Bytef.self).baseAddress, &length,
                           input.bindMemory(to: Bytef.self).baseAddress, uLong(encoded.count))
            }
        }
        return status == Z_OK && length == count ? decoded : nil
    }

    private static func applyAdjustment(_ adjustment: ImageColorAdjustment, to data: inout Data, components: Int) throws {
        try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let samples = bytes.bindMemory(to: UInt8.self)
            func adjusted(_ sample: Double) -> UInt8 {
                let value = (sample / 255 - 0.5) * adjustment.contrast + 0.5 + adjustment.brightness
                return UInt8((255 * min(1, max(0, value))).rounded())
            }
            for i in stride(from: 0, to: samples.count, by: components) {
                if i.isMultiple(of: 12_288) { try Task.checkCancellation() }
                if components == 1 { samples[i] = adjusted(Double(samples[i])); continue }
                let r = Double(samples[i]), g = Double(samples[i + 1]), b = Double(samples[i + 2])
                let luminance = r * 0.2126 + g * 0.7152 + b * 0.0722
                samples[i] = adjusted(luminance + (r - luminance) * adjustment.saturation)
                samples[i + 1] = adjusted(luminance + (g - luminance) * adjustment.saturation)
                samples[i + 2] = adjusted(luminance + (b - luminance) * adjustment.saturation)
            }
        }
    }

    private static func allowsCMYKAdjustment(tokens: [PDFContentToken], resources: CGPDFDictionaryRef?) -> Bool {
        // A simple page scope provides no place for an overprinting or
        // spot-painted object to interact with a changed separation.
        let complexOperators: Set<String> = ["gs", "sh", "SCN", "scn", "ri"]
        if tokens.contains(where: { complexOperators.contains($0.text) }) { return false }
        let processSpaces: Set<String> = ["/DeviceGray", "/DeviceRGB", "/DeviceCMYK"]
        let fonts = resources.flatMap { dictionary("Font", in: $0) }
        for index in tokens.indices {
            switch tokens[index].text {
            case "CS", "cs":
                guard index >= 1, processSpaces.contains(tokens[index - 1].text) else { return false }
            case "Tf":
                guard index >= 2, let fonts, let font = dictionary(String(tokens[index - 2].text.dropFirst()), in: fonts),
                      let subtype = name("Subtype", in: font), subtype != "Type3" else { return false }
            default: break
            }
        }
        return true
    }

    private static func supportsDCTParameters(_ image: CGPDFDictionaryRef, components: Int) -> Bool {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(image, "DecodeParms", &object), let object else { return true }
        var parameters = object
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array {
            var element: CGPDFObjectRef?
            guard CGPDFArrayGetCount(array) == 1, CGPDFArrayGetObject(array, 0, &element), let value = element else { return false }
            parameters = value
        }
        if CGPDFObjectGetType(parameters) == .null { return true }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(parameters, .dictionary, &dictionary), let dictionary else { return false }
        if CGPDFDictionaryGetCount(dictionary) == 0 { return true }
        var transform: CGPDFInteger = 0
        return CGPDFDictionaryGetCount(dictionary) == 1 &&
            CGPDFDictionaryGetInteger(dictionary, "ColorTransform", &transform) &&
            transform == (components == 1 ? 0 : 1)
    }

    private static func colorSpace(_ image: CGPDFDictionaryRef, resources: CGPDFDictionaryRef) -> (components: Int, profile: Data?)? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(image, "ColorSpace", &object), let object else { return nil }
        var space = object
        var named: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(space, .name, &named), let named {
            switch String(cString: named) {
            case "DeviceRGB": return (3, nil)
            case "DeviceGray": return (1, nil)
            case "DeviceCMYK": return (4, nil)
            default:
                guard let spaces = dictionary("ColorSpace", in: resources) else { return nil }
                var resolved: CGPDFObjectRef?
                guard CGPDFDictionaryGetObject(spaces, String(cString: named), &resolved), let resolved else { return nil }
                space = resolved
                var value: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(space, .name, &value), let value {
                    switch String(cString: value) {
                    case "DeviceRGB": return (3, nil)
                    case "DeviceGray": return (1, nil)
                    case "DeviceCMYK": return (4, nil)
                    default: return nil
                    }
                }
            }
        }
        var array: CGPDFArrayRef?, kind: UnsafePointer<CChar>?, stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(space, .array, &array), let array,
              CGPDFArrayGetName(array, 0, &kind), let kind, String(cString: kind) == "ICCBased",
              CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var count: CGPDFInteger = 0, length: CGPDFInteger = 0
        var format = CGPDFDataFormat.raw
        guard CGPDFDictionaryGetInteger(dict, "N", &count), [1, 3, 4].contains(count),
              CGPDFDictionaryGetInteger(dict, "Length", &length), (1...(16 * 1024 * 1024)).contains(length),
              let profile = CGPDFStreamCopyData(stream, &format), format == .raw,
              (128...(16 * 1024 * 1024)).contains(CFDataGetLength(profile)) else { return nil }
        let profileData = profile as Data
        guard String(decoding: profileData[36..<40], as: UTF8.self) == "acsp" else { return nil }
        let signature = String(decoding: profileData[16..<20], as: UTF8.self)
        if count == 4 {
            var range: CGPDFObjectRef?
            guard signature == "CMYK", !CGPDFDictionaryGetObject(dict, "Range", &range) else { return nil }
            return (count, profileData)
        }
        return (count == 3 && signature == "RGB ") || (count == 1 && signature == "GRAY") ? (count, profileData) : nil
    }

    private static func name(_ key: String, in dictionary: CGPDFDictionaryRef) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func dictionary(_ key: String, in dictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
    }

    private static func liveResources(_ page: CGPDFPage) -> CGPDFDictionaryRef? {
        var current = page.dictionary
        for _ in 0..<32 {
            guard let value = current else { return nil }
            if let resources = dictionary("Resources", in: value) { return resources }
            current = dictionary("Parent", in: value)
        }
        return nil
    }
}
