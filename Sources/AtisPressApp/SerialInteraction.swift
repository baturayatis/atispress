import AppKit
import ImpositionCore
import PDFEngine

enum SerialInteraction {
    static func moved(start:Point,proposed:Point,modifiers:NSEvent.ModifierFlags) -> Point {
        var q = proposed
        if !modifiers.contains(.option) { q = Point(q.x.rounded(),q.y.rounded()) }
        if modifiers.contains(.shift) {
            if abs(q.x-start.x) >= abs(q.y-start.y) { q.y = start.y } else { q.x = start.x }
        }
        return q
    }
    static func nudge(_ key:UInt16,shift:Bool) -> Point? {
        let step = shift ? 5.0 : 0.5
        switch key { case 123:return Point(-step,0); case 124:return Point(step,0); case 125:return Point(0,-step); case 126:return Point(0,step); default:return nil }
    }
}
extension Workspace {
    func placeSerial(_ id:UUID,corner:Int?) {
        guard let sheet = currentSheet,let side = currentSide,let serial = sheet.serialPlacements(side:side,kind:self.side,repetition:repetition).first(where:{$0.field.id == id}) else { return }
        let trim = PDFPreviewDrawing.localTrim(side.slots[serial.slotIndex])
        var copy = serial; copy.field.position = Point(0,0)
        let box = PDFSerialDrawing.bounds(copy).applying(PDFSerialDrawing.transform(copy))
        let x = corner.map { $0 % 2 == 0 ? -box.minX : trim.width-box.maxX } ?? (trim.width-box.width)/2-box.minX
        let y = corner.map { $0 < 2 ? -box.minY : trim.height-box.maxY } ?? (trim.height-box.height)/2-box.minY
        beginUndoGroup(); moveSerialField(id,to:Point(x,y),snap:false); endUndoGroup()
    }
    var serialTrimWarning:String? {
        guard let sheet = currentSheet,let side = currentSide else { return nil }
        for serial in sheet.serialPlacements(side:side,kind:self.side,repetition:repetition) {
            let trim = PDFPreviewDrawing.localTrim(side.slots[serial.slotIndex])
            let box = PDFSerialDrawing.bounds(serial).applying(PDFSerialDrawing.transform(serial))
            if !trim.contains(box) { return "Numara veya kod kesim alanının dışında; çıktıda kırpılır." }
        }
        return nil
    }
}
