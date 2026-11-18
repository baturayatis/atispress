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
        if tokens.count == 3, last.text == "R", let id = Int(first.text) { return try file.dictionary(id, maximumBytes: 256 * 1024) }
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

    func variant(pages: Set<Int>, adjustment: ImageColorAdjustment) throws -> (Data?, [String]) {
        guard adjustment.isValid else { return (nil, ["Renk değerleri geçersiz. Görseller özgün renkleriyle kullanıldı."]) }
        var output = file.data
        output.append(10)
        var entries: [Int: (Int, Int)] = [:]
        var next = (file.offsets.keys.max() ?? 0) + 1
        var warnings = Set<String>()
        func append(_ id: Int, generation: Int, dictionary: Data, stream: Data? = nil) {
            entries[id] = (output.count, generation)
            output.append(Data("\(id) \(generation) obj\n".utf8))
            output.append(dictionary)
            if let stream {
                output.append(Data("\nstream\n".utf8))
                output.append(stream)
                output.append(Data("\nendstream".utf8))
            }
            output.append(Data("\nendobj\n".utf8))
        }

        for number in pages.sorted() {
            try Task.checkCancellation()
            guard file.pages.indices.contains(number - 1), let page = document.page(at: number),
                  let content = pdfPageContent(page), content.count <= 4 * 1024 * 1024 else {
                warnings.insert("Bazı sayfa içerikleri güvenli biçimde incelenemedi.")
                continue
            }
            let pageID = file.pages[number - 1]
            var dictionary = try file.dictionary(pageID, maximumBytes: 256 * 1024)
            let tokens = pdfTokens(content)
            if tokens.last?.text == "BI" {
                warnings.insert("Satır içi görseller özgün renkleriyle kullanıldı.")
                // The tokenizer stops before inline binary data. Later image uses
                // on this page may share a name, so keep the entire page unchanged.
                continue
            }
            let uses = tokens.indices.dropFirst().compactMap { index -> PDFContentToken? in
                guard tokens[index].text == "Do", tokens[index - 1].text.hasPrefix("/") else { return nil }
                return tokens[index - 1]
            }
            let names = Set(uses.map(\.text))
            guard !names.isEmpty else { continue }
            guard var resources = try resources(for: dictionary), var objects = try resolved("/XObject", in: resources),
                  let liveResources = Self.liveResources(page), let liveObjects = Self.dictionary("XObject", in: liveResources) else {
                warnings.insert("Bazı PDF görsel kaynakları güvenli biçimde incelenemedi.")
                continue
            }
            var aliases: [String: String] = [:]
            var replacementImages: [Int: Int] = [:]
            for name in names.sorted() {
                try Task.checkCancellation()
                var stream: CGPDFStreamRef?
                guard !name.contains("#"), CGPDFDictionaryGetStream(liveObjects, String(name.dropFirst()), &stream),
                      let stream, let image = CGPDFStreamGetDictionary(stream) else {
                    warnings.insert("Bazı PDF görsel kaynakları güvenli biçimde incelenemedi.")
                    continue
                }
                guard Self.name("Subtype", in: image) == "Image" else {
                    warnings.insert("İç içe Form içeriği özgün renkleriyle kullanıldı.")
                    continue
                }
                guard let reference = file.value(name, pdfTokens(objects)), reference.count == 3,
                      reference.last?.text == "R", let id = Int(reference[0].text),
                      let generation = Int(reference[1].text), file.offsets[id]?.1 == generation else {
                    warnings.insert("Bazı görsel başvuruları güvenli biçimde değiştirilemedi.")
                    continue
                }
                let newID: Int
                if let existing = replacementImages[id] { newID = existing }
                else {
                    guard let imageData = try adjusted(stream, dictionary: image, resources: liveResources, adjustment: adjustment, warnings: &warnings) else { continue }
                    guard output.count + imageData.count <= 96 * 1024 * 1024 else {
                        warnings.insert("Renk düzenleme bellek sınırını aşan görseller özgün renkleriyle kullanıldı.")
                        continue
                    }
                    var imageDictionary = try file.dictionary(id, maximumBytes: 256 * 1024)
                    set("/Length", to: Data(String(imageData.count).utf8), in: &imageDictionary)
                    set("/Filter", to: Data("/FlateDecode".utf8), in: &imageDictionary)
                    set("/DecodeParms", to: nil, in: &imageDictionary)
                    newID = next
                    next += 1
                    replacementImages[id] = newID
                    append(newID, generation: 0, dictionary: imageDictionary, stream: imageData)
                }
                var alias = "/AtisPressColor\(newID)"
                while file.value(alias, pdfTokens(objects)) != nil { alias += "_" }
                set(alias, to: Data("\(newID) 0 R".utf8), in: &objects)
                aliases[name] = alias
            }
            if !aliases.isEmpty {
                // Use private aliases only at the edited Do operands. Forms,
                // masks or other pages may still reference the original name.
                var revised = content
                for use in uses.reversed() {
                    if let alias = aliases[use.text] { revised.replaceSubrange(use.range, with: Data(alias.utf8)) }
                }
                guard output.count + revised.count <= 96 * 1024 * 1024 else {
                    warnings.insert("Renk düzenleme bellek sınırını aşan görseller özgün renkleriyle kullanıldı.")
                    continue
                }
                let streamID = next
                next += 1
                append(streamID, generation: 0, dictionary: Data("<< /Length \(revised.count) >>".utf8), stream: revised)
                set("/Contents", to: Data("\(streamID) 0 R".utf8), in: &dictionary)
                set("/XObject", to: objects, in: &resources)
                set("/Resources", to: resources, in: &dictionary)
                append(pageID, generation: file.offsets[pageID]?.1 ?? 0, dictionary: dictionary)
            }
        }
        if entries.isEmpty {
            warnings.insert("Seçili işte renk düzenlemesine uygun görsel bulunamadı.")
            return (nil, warnings.sorted())
        }
        return (file.appendingXref(to: output, entries: entries, size: next), warnings.sorted())
    }

    private func adjusted(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, resources: CGPDFDictionaryRef,
                          adjustment: ImageColorAdjustment, warnings: inout Set<String>) throws -> Data? {
        guard let colorSpace = Self.colorSpace(dictionary, resources: resources) else {
            warnings.insert("CMYK, spot ve desteklenmeyen renk uzayları özgün renkleriyle kullanıldı.")
            return nil
        }
        let components = colorSpace.components
        if components == 1 && adjustment.saturation != 1 {
            warnings.insert("Doygunluk gri tonlamalı görsellere uygulanmadı.")
            if adjustment.brightness == 0 && adjustment.contrast == 1 { return nil }
        }
        let excluded = ["SMask", "Mask", "ImageMask", "SMaskInData", "Decode", "F", "FFilter", "FDecodeParms", "Alternates"]
        guard !excluded.contains(where: { key in
            var object: CGPDFObjectRef?
            return CGPDFDictionaryGetObject(dictionary, key, &object)
        }) else {
            warnings.insert("Maskeli, saydamlık bilgili veya özel kod çözmeli görseller özgün renkleriyle kullanıldı.")
            return nil
        }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits), bits == 8,
              width > 0, height > 0, width <= 12_000_000 / height / components else {
            warnings.insert("8 bit dışındaki veya boyut sınırını aşan görseller özgün renkleriyle kullanıldı.")
            return nil
        }
        let filter = Self.name("Filter", in: dictionary)
        var filterObject: CGPDFObjectRef?
        let hasFilter = CGPDFDictionaryGetObject(dictionary, "Filter", &filterObject)
        var filterArray: CGPDFArrayRef?, dct: UnsafePointer<CChar>?
        let arrayDCT = CGPDFDictionaryGetArray(dictionary, "Filter", &filterArray) &&
            filterArray.map { CGPDFArrayGetCount($0) == 1 && CGPDFArrayGetName($0, 0, &dct) } == true &&
            dct.map { String(cString: $0) == "DCTDecode" } == true
        var format = CGPDFDataFormat.raw
        var data: Data
        if filter == "DCTDecode" || arrayDCT {
            guard Self.supportsDCTParameters(dictionary, components: components),
                  let bytes = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded,
                  let samples = try PDFJPEGImageSamples.decode(bytes as Data, width: width, height: height,
                                                              components: components, pdfICC: colorSpace.profile) else {
                warnings.insert("Desteklenmeyen, bozuk veya ICC profili uyuşmayan JPEG görseller özgün renkleriyle kullanıldı.")
                return nil
            }
            data = samples
        } else {
            guard !hasFilter || filter == "FlateDecode",
                  let bytes = CGPDFStreamCopyData(stream, &format), format == .raw,
                  CFDataGetLength(bytes) == width * height * components else {
                warnings.insert("JPEG 2000, çoklu filtreli veya desteklenmeyen sıkıştırmalı görseller özgün renkleriyle kullanıldı.")
                return nil
            }
            data = Data(bytes as Data)
        }
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
                    default: return nil
                    }
                }
            }
        }
        var array: CGPDFArrayRef?, kind: UnsafePointer<CChar>?, stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(space, .array, &array), let array,
              CGPDFArrayGetName(array, 0, &kind), let kind, String(cString: kind) == "ICCBased",
              CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var count: CGPDFInteger = 0
        var format = CGPDFDataFormat.raw
        guard CGPDFDictionaryGetInteger(dict, "N", &count), count == 1 || count == 3,
              let profile = CGPDFStreamCopyData(stream, &format), format == .raw,
              CFDataGetLength(profile) >= 128 else { return nil }
        let profileData = profile as Data
        guard String(decoding: profileData[36..<40], as: UTF8.self) == "acsp" else { return nil }
        let signature = String(decoding: profileData[16..<20], as: UTF8.self)
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
