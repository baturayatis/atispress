import XCTest
import AppKit
import SwiftUI
import ImpositionCore
import PDFEngine
@testable import AtisPressApp

@MainActor final class SerialDragTests:XCTestCase {
    func fixture() async throws -> Workspace {
        let m = Workspace(bookmarkCreator:{ _ in Data() })
        m.project = Project(pages:(1...2).map { SourcePage(number:$0,trimSize:Size(85,55),availableBleed:3) },sheet:SheetSpec(size:Size(200,140)),settings:ImpositionSettings(bleed:0,cropMarkLength:0,cropMarkOffset:0),stepAndRepeat:StepAndRepeatSettings(columns:2,rows:2,quantity:4))
        m.addSerialField()
        m.editableSerialFields[0].position = Point(12,8)
        m.editableSerialFields[0].sides = .both
        for _ in 0..<200 where m.planning { try await Task.sleep(for:.milliseconds(10)) }
        return m
    }
    func testVisibleAllSidesCanvasHitAndDragMovesSerialAtAutoFit() async throws {
        let m = try await fixture()
        let host = NSHostingView(rootView:AllSheetsPreview(model:m))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = host; host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
        func find(_ v:NSView) -> AllSheetsScrollView? { (v as? AllSheetsScrollView) ?? v.subviews.compactMap(find).first }
        let scroll = try XCTUnwrap(find(host)); scroll.layoutSubtreeIfNeeded()
        let doc = try XCTUnwrap(scroll.documentView as? AllSheetsDocument); doc.refreshVisible()
        for zoom in [scroll.magnification,0.4,2.0] {
        scroll.magnification = zoom
        for side in [SideKind.front,.back] {
            scroll.scrollToSheet(0,side:side); doc.refreshVisible()
            let canvas = try XCTUnwrap(doc.subviews.flatMap(\.subviews).compactMap { $0 as? SheetCanvasView }.first { $0.sideKind == side })
            let placement = try XCTUnwrap(canvas.sheet?.serialPlacements(side:canvas.side,kind:side,repetition:0).first)
            let slot = canvas.side.slots[placement.slotIndex]
            let bounds = PDFSerialDrawing.bounds(placement)
            let local = CGPoint(x:bounds.midX,y:bounds.midY).applying(PDFSerialDrawing.transform(placement)).applying(PDFPreviewDrawing.slotTransform(slot))
            let point = canvas.convert(CGPoint(x:32+local.x*72/25.4,y:32+local.y*72/25.4),to:nil)
            m.selectedSerialID = nil
            let before = m.editableSerialFields[0].position
            func event(_ type:NSEvent.EventType,_ q:CGPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:q,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)! }
            XCTAssertTrue(canvas.hitTest(canvas.convert(point,from:nil)) === canvas)
            canvas.mouseDown(with:event(.leftMouseDown,point))
            XCTAssertEqual(m.selectedSerialID,placement.field.id)
            canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:point.x+10,y:point.y+10)))
            canvas.mouseUp(with:event(.leftMouseUp,point))
            XCTAssertNotEqual(m.editableSerialFields[0].position,before,"Visible serial drag must update the inline editor model")
        }
        }
    }
}

extension SerialDragTests {
    func testTextAndQRDragFrontBackAtSeveralZoomsWithNudgeSnapAndUndo() async throws {
        for kind in [SerialCodeSettings.Kind.text,.qr] {
            for zoom in [0.35,1.0,2.5] {
                for face in [SideKind.front,.back] {
                    let m = try await fixture()
                    m.editableSerialFields[0].kind = kind
                    let scroll = PreviewScrollView(frame:NSRect(x:0,y:0,width:600,height:500))
                    scroll.allowsMagnification = true; scroll.minMagnification = 0.01; scroll.maxMagnification = 12
                    let canvas = SheetCanvasView(); scroll.documentView = canvas
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:500),styleMask:[.titled],backing:.buffered,defer:false)
                    window.contentView = scroll
                    let sheet = try XCTUnwrap(m.currentSheet)
                    canvas.connectSerialEditing(m)
                    canvas.configure(sheet:sheet,side:face == .front ? sheet.front : sheet.back,source:nil,overlays:.artworkOnly,highlighted:[],kind:face)
                    scroll.magnification = zoom
                    let serial = try XCTUnwrap(sheet.serialPlacements(side:canvas.side,kind:face,repetition:0).first)
                    let slot = canvas.side.slots[serial.slotIndex],box = PDFSerialDrawing.bounds(serial)
                    let local = CGPoint(x:box.midX,y:box.midY).applying(PDFSerialDrawing.transform(serial))
                    func point(_ local:CGPoint) -> CGPoint {
                        let q = local.applying(PDFPreviewDrawing.slotTransform(slot))
                        return canvas.convert(CGPoint(x:32+q.x*72/25.4,y:32+q.y*72/25.4),to:nil)
                    }
                    func event(_ type:NSEvent.EventType,_ local:CGPoint,_ modifiers:NSEvent.ModifierFlags = []) -> NSEvent {
                        NSEvent.mouseEvent(with:type,location:point(local),modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                    }
                    let original = m.editableSerialFields[0].position
                    let scrollOrigin = scroll.contentView.bounds.origin
                    canvas.mouseDown(with:event(.leftMouseDown,local))
                    canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:local.x+3.24,y:local.y+1.31),[.option]))
                    XCTAssertEqual(m.editableSerialFields[0].position.x,original.x+3.24,accuracy:0.00001)
                    XCTAssertEqual(m.editableSerialFields[0].position.y,original.y+1.31,accuracy:0.00001)
                    canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:local.x+6.2,y:local.y+1.2),[.shift]))
                    canvas.mouseUp(with:event(.leftMouseUp,local))
                    XCTAssertEqual(m.editableSerialFields[0].position,Point(original.x+6,original.y))
                    XCTAssertEqual(scroll.contentView.bounds.origin,scrollOrigin,"A field drag cannot pan")
                    m.undoEdit(); XCTAssertEqual(m.editableSerialFields[0].position,original,"One drag is one undo")
                    m.redoEdit()
                    func key(_ code:UInt16,_ shift:Bool) -> NSEvent { NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shift ? [.shift] : [],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)! }
                    canvas.keyDown(with:key(124,false)); XCTAssertEqual(m.editableSerialFields[0].position.x,original.x+6.5)
                    canvas.keyDown(with:key(126,true)); XCTAssertEqual(m.editableSerialFields[0].position.y,original.y+5)
                    window.contentView = nil
                }
            }
        }
    }
    func testSnapFreeAndAxisLockAndTrimWarning() async throws {
        XCTAssertEqual(SerialInteraction.moved(start:Point(4,5),proposed:Point(7.2,9.1),modifiers:[]),Point(7,9))
        XCTAssertEqual(SerialInteraction.moved(start:Point(4,5),proposed:Point(7.2,9.1),modifiers:[.option,.shift]),Point(4,9.1))
        let m = try await fixture()
        m.moveSerialField(m.editableSerialFields[0].id,to:Point(-5,3))
        XCTAssertNotNil(m.serialTrimWarning)
        m.placeSerial(m.editableSerialFields[0].id,corner:nil)
        XCTAssertNil(m.serialTrimWarning)
    }
}
