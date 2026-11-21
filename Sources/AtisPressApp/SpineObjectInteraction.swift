import AppKit
import ImpositionCore

struct SpineObjectInteraction {
    enum Handle { case move, resize, rotate, delete }

    let bounds: CGRect
    let unit: CGFloat
    var center: CGPoint { CGPoint(x:bounds.midX,y:bounds.midY) }
    var resize: CGPoint { CGPoint(x:bounds.maxX,y:bounds.minY) }
    var rotate: CGPoint { CGPoint(x:bounds.midX,y:bounds.maxY+16*unit) }
    var delete: CGPoint { CGPoint(x:bounds.maxX+10*unit,y:bounds.maxY+10*unit) }

    func hit(_ point: CGPoint) -> Handle? {
        for (handle,target) in [(Handle.resize,resize),(.rotate,rotate),(.delete,delete)] {
            if hypot(point.x-target.x,point.y-target.y) <= 6*unit { return handle }
        }
        return nil
    }

    func edited(_ object: FreeSpineObject,handle: Handle,start: CGPoint,current: CGPoint) -> FreeSpineObject {
        var next = object
        switch handle {
        case .move:
            next.x = min(10_000,max(-10_000,(object.x+current.x-start.x).rounded()))
            next.y = min(10_000,max(-10_000,(object.y+current.y-start.y).rounded()))
        case .resize:
            let from = hypot(start.x-center.x,start.y-center.y)
            let to = hypot(current.x-center.x,current.y-center.y)
            if from > 0 {
                let value = object.size*to/from
                next.size = min(object.sizeRange.upperBound,max(object.sizeRange.lowerBound,value))
            }
        case .rotate:
            let from = atan2(start.y-center.y,start.x-center.x)
            let to = atan2(current.y-center.y,current.x-center.x)
            next.rotation = (object.rotation+Double(to-from)*180/Double.pi).rounded().truncatingRemainder(dividingBy:360)
        case .delete: break
        }
        return next
    }

    func draw(in context: CGContext,overflow: Bool) {
        context.setLineWidth(unit)
        let border = overflow ? DesignSystem.errorNS : DesignSystem.focusNS
        context.setStrokeColor(border.cgColor)
        context.stroke(bounds)
        context.move(to:CGPoint(x:bounds.midX,y:bounds.maxY))
        context.addLine(to:rotate); context.strokePath()
        for (point,circle) in [(resize,false),(rotate,true),(delete,true)] {
            let rect = CGRect(x:point.x-4*unit,y:point.y-4*unit,width:8*unit,height:8*unit)
            context.setFillColor(DesignSystem.paperNS.cgColor)
            if circle {
                context.fillEllipse(in:rect)
                context.strokeEllipse(in:rect)
            } else {
                context.fill(rect)
                context.stroke(rect)
            }
        }
        for sign in [-1.0,1.0] {
            context.move(to:CGPoint(x:delete.x-2*unit,y:delete.y+sign*2*unit))
            context.addLine(to:CGPoint(x:delete.x+2*unit,y:delete.y-sign*2*unit))
        }
        context.strokePath()
    }
}
