import Foundation

enum CompositionGeometry {
    static func transformed(_ crop:CGRect,scale:Double,translation:CGSize,anchor:CGPoint,viewport:CGSize) -> CGRect {
        let h=crop.height/max(0.05,scale),w=crop.width/max(0.05,scale)
        return .init(x:crop.minX+anchor.x*(crop.width-w)-translation.width/max(1,viewport.width)*w,
                     y:crop.minY+anchor.y*(crop.height-h)-translation.height/max(1,viewport.height)*h,width:w,height:h)
    }
    static func reframed(_ crop: CGRect, source: CGSize, aspect: OutputAspectRatio) -> CGRect {
        let h=min(crop.height,source.height,source.width/aspect.value),w=h*aspect.value
        return .init(x:min(source.width-w,max(0,crop.midX-w/2)),y:min(source.height-h,max(0,crop.midY-h/2)),width:w,height:h)
    }
    static func constrain(_ proposed:CGRect,source:CGSize,samples:[TargetSample],reference:TargetSample,protect:Bool,aspect:OutputAspectRatio = .portrait) -> CGRect {
        let bodies=samples.map {($0.protection ?? $0.body).cgRect}
        let top=(bodies.map(\.minY).min() ?? 0)*source.height,bottom=(bodies.map(\.maxY).max() ?? 1)*source.height
        let maximum=min(source.height,source.width/aspect.value)
        let minimum=protect ? min(maximum,max((bottom-top)*1.10,(bodies.map(\.width).max() ?? 0)*source.width/aspect.value*1.10)) : min(120,maximum)
        let h=min(maximum,max(minimum,proposed.height)),w=h*aspect.value
        var lx=0.0,ux=source.width-w,ly=0.0,uy=source.height-h
        let body=(protect ? reference.protection ?? reference.body : reference.body).cgRect
        if protect {
            let a=max(lx,body.maxX*source.width-w+w*0.025),b=min(ux,body.minX*source.width-w*0.025)
            if a<=b { lx=a;ux=b }
            else {
                let requiredL=max(lx,body.maxX*source.width-w),requiredU=min(ux,body.minX*source.width)
                if requiredL<=requiredU {lx=requiredL;ux=requiredU}
            }
            let c=max(ly,bottom-h),d=min(uy,top)
            if c<=d {ly=c;uy=d}
        } else {
            lx=max(lx,body.midX*source.width-w*0.95);ux=min(ux,body.midX*source.width-w*0.05)
            ly=max(ly,body.midY*source.height-h*0.95);uy=min(uy,body.midY*source.height-h*0.05)
        }
        return .init(x:min(ux,max(lx,proposed.midX-w/2)),y:min(uy,max(ly,proposed.midY-h/2)),width:w,height:h)
    }
}
