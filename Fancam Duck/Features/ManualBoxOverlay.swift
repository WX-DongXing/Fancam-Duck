import SwiftUI

/// All gestures operate in the upright image, excluding player letterboxing.
struct ManualBoxOverlay: View {
    @Binding var box: NormalizedRect?
    @State private var gestureStart: NormalizedRect?
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment:.topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:2).onChanged { value in
                        let start = CGPoint(x:value.startLocation.x/size.width,y:value.startLocation.y/size.height)
                        let end = CGPoint(x:value.location.x/size.width,y:value.location.y/size.height)
                        box = .drawing(from:start,to:end)
                    })
                    .accessibilityLabel("拖动框选人物区域")
                if let box {
                    let frame = CGRect(x:box.x*size.width,y:box.y*size.height,width:box.width*size.width,height:box.height*size.height)
                    Path { p in p.addRect(CGRect(origin:.zero,size:size)); p.addRect(frame) }
                        .fill(.black.opacity(0.45),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                    RoundedRectangle(cornerRadius:10).fill(Color.acAccent.opacity(0.06))
                        .overlay { RoundedRectangle(cornerRadius:10).stroke(Color.acAccent,lineWidth:2) }
                        .frame(width:frame.width,height:frame.height).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance:1).onChanged { value in
                            if gestureStart == nil { gestureStart = box }
                            self.box = ManualBoxGeometry.move(gestureStart!,dx:value.translation.width/size.width,dy:value.translation.height/size.height)
                        }.onEnded { _ in gestureStart=nil })
                        .position(x:frame.midX,y:frame.midY)
                        .accessibilityLabel("移动人物框")
                        .accessibilityAction(named:Text("向左移动")) { self.box=ManualBoxGeometry.move(box,dx:-0.02,dy:0) }
                        .accessibilityAction(named:Text("向右移动")) { self.box=ManualBoxGeometry.move(box,dx:0.02,dy:0) }
                        .accessibilityAction(named:Text("向上移动")) { self.box=ManualBoxGeometry.move(box,dx:0,dy:-0.02) }
                        .accessibilityAction(named:Text("向下移动")) { self.box=ManualBoxGeometry.move(box,dx:0,dy:0.02) }
                        .accessibilityIdentifier("manualBox")
                    ForEach(Array(ManualBoxGeometry.Corner.allCases.enumerated()),id:\.offset) { index, corner in
                        let left = corner == .topLeft || corner == .bottomLeft
                        let top = corner == .topLeft || corner == .topRight
                        Circle().fill(Color.acAccent).frame(width:12,height:12)
                            .frame(width:48,height:48).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance:1).onChanged { value in
                                if gestureStart == nil { gestureStart=box }
                                self.box=ManualBoxGeometry.resize(gestureStart!,corner:corner,dx:value.translation.width/size.width,dy:value.translation.height/size.height)
                            }.onEnded { _ in gestureStart=nil })
                            .position(x:left ? frame.minX : frame.maxX,y:top ? frame.minY : frame.maxY)
                            .accessibilityLabel("调整人物框角 \(index+1)")
                            .accessibilityIdentifier("manualCorner\(index)")
                            .accessibilityAdjustableAction { direction in
                                let amount=direction == .increment ? 0.02 : -0.02
                                self.box=ManualBoxGeometry.resize(box,corner:corner,dx:left ? -amount : amount,dy:top ? -amount : amount)
                            }
                    }
                }
            }
        }
    }
}
