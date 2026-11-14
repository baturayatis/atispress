import Foundation

enum TRFormat {
    static let locale = Locale(identifier:"tr_TR")
    static let detail = FloatingPointFormatStyle<Double>.number.locale(locale).grouping(.never).precision(.fractionLength(0...2))
    static func dimension(_ value:Double,detail:Bool = false) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(0...(detail ? 2 : 1))))
    }
    static func size(_ width:Double,_ height:Double) -> String { "\(dimension(width)) × \(dimension(height)) mm" }
    // Localize numeric fragments from core diagnostics without changing stored plan messages.
    static func presentation(_ text:String) -> String {
        let expression = try! NSRegularExpression(pattern:#"(?<![A-Za-z0-9/])(-?\d+\.\d+)(?![A-Za-z0-9/])"#)
        var result = text
        for match in expression.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
            guard let range = Range(match.range,in:result),let value = Double(result[range]) else { continue }
            result.replaceSubrange(range,with:dimension(value))
        }
        return result
    }
}
