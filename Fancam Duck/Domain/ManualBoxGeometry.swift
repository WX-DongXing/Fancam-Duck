import Foundation

enum ManualBoxGeometry {
    enum Edge: String, CaseIterable {
        case top, bottom, left, right
        var title:String {switch self {case .top:"上";case .bottom:"下";case .left:"左";case .right:"右"}}
        var horizontal:Bool {self == .top || self == .bottom}
    }
    static func resize(_ box:NormalizedRect,edge:Edge,dx:Double,dy:Double) -> NormalizedRect {
        switch edge {
        case .top: resize(box,corner:.topLeft,dx:0,dy:dy)
        case .bottom: resize(box,corner:.bottomLeft,dx:0,dy:dy)
        case .left: resize(box,corner:.topLeft,dx:dx,dy:0)
        case .right: resize(box,corner:.topRight,dx:dx,dy:0)
        }
    }
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    static func move(_ box: NormalizedRect, dx: Double, dy: Double) -> NormalizedRect {
        .init(x: min(1-box.width,max(0,box.x+dx)),y:min(1-box.height,max(0,box.y+dy)),width:box.width,height:box.height)
    }
    static func resize(_ box: NormalizedRect, corner: Corner, dx: Double, dy: Double) -> NormalizedRect {
        var left=box.x, right=box.x+box.width, top=box.y, bottom=box.y+box.height
        switch corner {
        case .topLeft: left=min(right-0.06,max(0,left+dx)); top=min(bottom-0.1,max(0,top+dy))
        case .topRight: right=max(left+0.06,min(1,right+dx)); top=min(bottom-0.1,max(0,top+dy))
        case .bottomLeft: left=min(right-0.06,max(0,left+dx)); bottom=max(top+0.1,min(1,bottom+dy))
        case .bottomRight: right=max(left+0.06,min(1,right+dx)); bottom=max(top+0.1,min(1,bottom+dy))
        }
        return .init(x:left,y:top,width:right-left,height:bottom-top)
    }
}
