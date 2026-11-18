import ColorSync
import Foundation

enum PDFCMYKImageColor {
    /// Round-trip through a defined working space and the same embedded
    /// press profile. Pixels unaffected by the controls keep their ink values.
    static func adjust(_ samples: Data, width: Int, height: Int, profile: Data,
                       editRGB: (inout Data) throws -> Void) throws -> Data? {
        guard let (toRGB, toPress) = transforms(for: profile) else { return nil }

        let pixelCount = width * height
        var originalRGB = Data(count: pixelCount * 3)
        try Task.checkCancellation()
        guard convert(toRGB, samples, into: &originalRGB, width: width, height: height, inputChannels: 4, outputChannels: 3) else { return nil }
        var editedRGB = originalRGB
        try editRGB(&editedRGB)
        guard editedRGB != originalRGB else { return samples }

        var editedCMYK = Data(count: samples.count)
        guard convert(toPress, editedRGB, into: &editedCMYK, width: width, height: height, inputChannels: 3, outputChannels: 4) else { return nil }
        try editedCMYK.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            try samples.withUnsafeBytes { (original: UnsafeRawBufferPointer) in
                try originalRGB.withUnsafeBytes { (before: UnsafeRawBufferPointer) in
                    try editedRGB.withUnsafeBytes { (after: UnsafeRawBufferPointer) in
                        for pixel in 0..<pixelCount {
                            if pixel.isMultiple(of: 4096) { try Task.checkCancellation() }
                            let rgb = pixel * 3
                            if before[rgb] == after[rgb], before[rgb + 1] == after[rgb + 1], before[rgb + 2] == after[rgb + 2] {
                                let ink = pixel * 4
                                for channel in ink..<(ink + 4) { output[channel] = original[channel] }
                            }
                        }
                    }
                }
            }
        }
        return editedCMYK
    }

    static func canAdjust(profile: Data) -> Bool { transforms(for: profile) != nil }

    private static func transforms(for profile: Data) -> (ColorSyncTransform, ColorSyncTransform)? {
        guard (128...(4 * 1024 * 1024)).contains(profile.count),
              profile.prefix(4).reduce(0, { ($0 << 8) + Int($1) }) == profile.count,
              String(decoding: profile[12..<20], as: UTF8.self) == "prtrCMYK",
              let press = ColorSyncProfileCreate(profile as CFData, nil)?.takeRetainedValue(),
              ColorSyncProfileVerify(press, nil, nil),
              ColorSyncProfileContainsTag(press, "A2B1" as CFString),
              ColorSyncProfileContainsTag(press, "B2A1" as CFString),
              let rgb = ColorSyncProfileCreateWithName(kColorSyncSRGBProfile.takeUnretainedValue())?.takeRetainedValue(),
              let toRGB = transform(from: press, to: rgb), let toPress = transform(from: rgb, to: press) else { return nil }

        return (toRGB, toPress)
    }

    private static func transform(from: ColorSyncProfile, to: ColorSyncProfile) -> ColorSyncTransform? {
        func step(_ profile: ColorSyncProfile, _ direction: CFString) -> [String: Any] {
            [
                kColorSyncProfile.takeUnretainedValue() as String: profile,
                kColorSyncRenderingIntent.takeUnretainedValue() as String: kColorSyncRenderingIntentRelative.takeUnretainedValue(),
                kColorSyncTransformTag.takeUnretainedValue() as String: direction
            ]
        }
        let sequence = [step(from, kColorSyncTransformDeviceToPCS.takeUnretainedValue()),
                        step(to, kColorSyncTransformPCSToDevice.takeUnretainedValue())]
        return ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue()
    }

    private static func convert(_ transform: ColorSyncTransform, _ source: Data, into destination: inout Data,
                                width: Int, height: Int, inputChannels: Int, outputChannels: Int) -> Bool {
        let layout = kColorSyncAlphaNone.rawValue
        return destination.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                ColorSyncTransformConvert(transform, width, height,
                                          target.baseAddress, kColorSync8BitInteger, layout, width * outputChannels,
                                          input.baseAddress, kColorSync8BitInteger, layout, width * inputChannels, nil)
            }
        }
    }
}
