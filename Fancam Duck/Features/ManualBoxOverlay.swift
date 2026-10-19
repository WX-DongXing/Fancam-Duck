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
                    Rectangle().fill(Color.acAccent.opacity(0.06))
                        .overlay { Rectangle().stroke(Color.acAccent,lineWidth:2) }
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
                    ForEach(ManualBoxGeometry.Edge.allCases,id:\.self) {edge in
                        let handleSize=CGSize(width:edge.horizontal ? min(18,frame.width*0.35) : min(3,frame.width),
                                              height:edge.horizontal ? min(3,frame.height) : min(18,frame.height*0.35))
                        Rectangle().fill(Color.acAccent)
                            .frame(width:handleSize.width,height:handleSize.height)
                            // Keep a clear center drag area even when the person box is small.
                            .frame(width:edge.horizontal ? min(48,frame.width) : min(48,frame.width*0.4),
                                   height:edge.horizontal ? min(48,frame.height*0.4) : min(48,frame.height))
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance:1).onChanged {value in
                                if gestureStart == nil {gestureStart=box}
                                self.box=ManualBoxGeometry.resize(gestureStart!,edge:edge,dx:value.translation.width/size.width,dy:value.translation.height/size.height)
                            }.onEnded {_ in gestureStart=nil})
                            .position(x:edge == .left ? frame.minX : edge == .right ? frame.maxX : frame.midX,
                                      y:edge == .top ? frame.minY : edge == .bottom ? frame.maxY : frame.midY)
                            .accessibilityLabel("调整人物框"+edge.title+"边")
                            .accessibilityIdentifier("manualEdge-"+edge.rawValue)
                            .accessibilityAdjustableAction {direction in
                                let amount=(direction == .increment ? 0.02 : -0.02) * (edge == .top || edge == .left ? -1 : 1)
                                self.box=ManualBoxGeometry.resize(box,edge:edge,dx:amount,dy:amount)
                            }
                    }
                }
            }
        }
    }
}
