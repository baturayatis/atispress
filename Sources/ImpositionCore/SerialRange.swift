import Foundation

public enum SerialRangeError: LocalizedError {
    case zeroStep, wrongDirection, incompleteStep, overflow
    public var errorDescription: String? {
        switch self {
        case .zeroStep: return "Artış 0 iken bitiş numarası adedi belirleyemez. Adet alanını değiştirin."
        case .wrongDirection: return "Bitiş numarası, başlangıç ve artış yönüyle uyuşmuyor."
        case .incompleteStep: return "Bitiş numarası artış adımına tam oturmuyor."
        case .overflow: return "Sayı bu sistemin 64 bit tam sayı kapasitesini aşıyor."
        }
    }
}
extension SerialField {
    public var digitsAreManual: Bool {
        get { fixedDigits ?? (digits != 4) }
        set { fixedDigits = newValue }
    }
    public var showsEndNumber: Bool {
        get { endNumberEnabled ?? false }
        set { endNumberEnabled = newValue }
    }
    public func quantity(endingAt end: Int64) throws -> Int {
        guard step != 0 else { throw SerialRangeError.zeroStep }
        guard step > 0 ? end >= start : end <= start else { throw SerialRangeError.wrongDirection }
        let distance = step > 0 ? UInt64(bitPattern: end) &- UInt64(bitPattern: start) : UInt64(bitPattern: start) &- UInt64(bitPattern: end)
        guard distance % step.magnitude == 0 else { throw SerialRangeError.incompleteStep }
        let count = (distance/step.magnitude).addingReportingOverflow(1)
        guard !count.overflow,count.partialValue <= UInt64(Int.max) else { throw SerialRangeError.overflow }
        return Int(count.partialValue)
    }
    public func requiredDigits(quantity: Int) -> Int? {
        guard quantity > 0,let end = value(at: quantity-1) else { return nil }
        return max(String(start.magnitude).count,String(end.magnitude).count)
    }
    public func adjustedDigits(quantity: Int) -> SerialField {
        var field = self
        if !digitsAreManual,let required = requiredDigits(quantity: quantity),required > digits {
            field.digits = required; field.autoIncreasedDigits = required
        }
        return field
    }
    public func digitNote(quantity: Int) -> String? {
        guard quantity > 0 else { return "Adet en az 1 olmalıdır." }
        guard let required = requiredDigits(quantity: quantity) else { return SerialRangeError.overflow.localizedDescription }
        if digitsAreManual,required > digits {
            return "Basamak elle \(digits) olarak sabit: aralık \(required) basamak gerektiriyor. Tam numara korunur."
        }
        if let autoIncreasedDigits,!digitsAreManual { return "Basamak \(autoIncreasedDigits)'e çıkarıldı" }
        return nil
    }
    public func rangeDescription(quantity: Int,sheetCount: Int) -> String {
        guard quantity > 0 else { return "Numara aralığı: Adet en az 1 olmalıdır." }
        let field = adjustedDigits(quantity: quantity)
        guard quantity > 0,let first = field.text(at: 0),let last = field.text(at: quantity-1) else {
            return "Numara aralığı: hesaplanamadı — \(SerialRangeError.overflow.localizedDescription)"
        }
        return "Numara aralığı: \(first) → \(last) (\(quantity) adet, \(sheetCount > 0 ? "\(sheetCount) tabaka" : "tabaka bekleniyor"))"
    }
}
extension Sheet {
    public var excessCopies: Int {
        guard let layout = repeatLayout,let quantity = layout.requestedQuantity,layout.copiesPerSheet > 0 else { return 0 }
        let remaining = quantity % layout.copiesPerSheet
        return remaining == 0 ? 0 : layout.copiesPerSheet-remaining
    }
    public var producedQuantityDescription: String {
        guard let layout = repeatLayout,repeatCount > 0,layout.copiesPerSheet > 0 else { return "0" }
        let value = UInt64(repeatCount).multipliedReportingOverflow(by: UInt64(layout.copiesPerSheet))
        return value.overflow ? "Sayısal kapasite aşıldı" : String(value.partialValue)
    }
}
