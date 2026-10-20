import SwiftUI

/// One fixed image-space gesture owns drawing, moving and resizing.
struct ManualBoxOverlay: View {
    @Binding var box: NormalizedRect?
    private enum Action {case draw, move, resize(ManualBoxGeometry.Edge)}
    private struct Drag {let action:Action;let initial:NormalizedRect?}
    @State private var drag:Drag?
    @GestureState private var dragging=false

    var body: some View {
        GeometryReader {geometry in
            let size=geometry.size
            ZStack(alignment:.topLeading) {
                Color.clear
                if let box {
                    let frame=pixelRect(box,size:size)
                    Path {p in p.addRect(CGRect(origin:.zero,size:size));p.addRect(frame)}
                        .fill(.black.opacity(0.45),style:FillStyle(eoFill:true))
                    Rectangle().fill(Color.acAccent.opacity(0.06))
                        .overlay {Rectangle().stroke(Color.acAccent,lineWidth:2)}
                        .frame(width:frame.width,height:frame.height)
                        .position(x:frame.midX,y:frame.midY)
                        .accessibilityLabel("移动人物框")
                        .accessibilityIdentifier("manualBox")
                        .accessibilityAction(named:Text("向左移动")) {self.box=ManualBoxGeometry.move(box,dx:-0.02,dy:0)}
                        .accessibilityAction(named:Text("向右移动")) {self.box=ManualBoxGeometry.move(box,dx:0.02,dy:0)}
                        .accessibilityAction(named:Text("向上移动")) {self.box=ManualBoxGeometry.move(box,dx:0,dy:-0.02)}
                        .accessibilityAction(named:Text("向下移动")) {self.box=ManualBoxGeometry.move(box,dx:0,dy:0.02)}
                    ForEach(ManualBoxGeometry.Edge.allCases,id:\.self) {edge in
                        let hit=handleRect(edge,frame:frame)
                        Rectangle().fill(Color.acAccent)
                            .frame(width:edge.horizontal ? min(18,frame.width*0.35) : min(3,frame.width),
                                   height:edge.horizontal ? min(3,frame.height) : min(18,frame.height*0.35))
                            .frame(width:hit.width,height:hit.height)
                            .position(x:hit.midX,y:hit.midY)
                            .accessibilityLabel("调整人物框"+edge.title+"边")
                            .accessibilityIdentifier("manualEdge-"+edge.rawValue)
                            .accessibilityAdjustableAction {direction in
                                let amount=(direction == .increment ? 0.02 : -0.02) * (edge == .top || edge == .left ? -1 : 1)
                                self.box=ManualBoxGeometry.resize(box,edge:edge,dx:amount,dy:amount)
                            }
                    }
                }
            }
            .frame(width:size.width,height:size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.local)
                .updating($dragging) {_,active,_ in active=true}
                .onChanged {value in
                    guard size.width>0,size.height>0 else {return}
                    if drag == nil {
                        var action=Action.draw
                        if let box {
                            let frame=pixelRect(box,size:size)
                            if let edge=ManualBoxGeometry.Edge.allCases.first(where:{handleRect($0,frame:frame).contains(value.startLocation)}) {
                                action = .resize(edge)
                            } else if frame.contains(value.startLocation) {action = .move}
                        }
                        drag=Drag(action:action,initial:box)
                    }
                    guard let drag else {return}
                    let dx=value.translation.width/size.width,dy=value.translation.height/size.height
                    switch drag.action {
                    case .draw:
                        box = .drawing(from:.init(x:value.startLocation.x/size.width,y:value.startLocation.y/size.height),
                                       to:.init(x:value.location.x/size.width,y:value.location.y/size.height))
                    case .move:
                        if let initial=drag.initial {box=ManualBoxGeometry.move(initial,dx:dx,dy:dy)}
                    case .resize(let edge):
                        if let initial=drag.initial {box=ManualBoxGeometry.resize(initial,edge:edge,dx:dx,dy:dy)}
                    }
                }.onEnded {_ in drag=nil})
            .onChange(of:dragging) {_,active in if !active {drag=nil}}
            .onDisappear {drag=nil}
            .transaction {$0.animation=nil;$0.disablesAnimations=true}
        }
    }

    private func pixelRect(_ box:NormalizedRect,size:CGSize)->CGRect {
        CGRect(x:box.x*size.width,y:box.y*size.height,width:box.width*size.width,height:box.height*size.height)
    }
    private func handleRect(_ edge:ManualBoxGeometry.Edge,frame:CGRect)->CGRect {
        let width=edge.horizontal ? min(48,frame.width) : min(48,frame.width*0.4)
        let height=edge.horizontal ? min(48,frame.height*0.4) : min(48,frame.height)
        let x=edge == .left ? frame.minX : edge == .right ? frame.maxX : frame.midX
        let y=edge == .top ? frame.minY : edge == .bottom ? frame.maxY : frame.midY
        return CGRect(x:x-width/2,y:y-height/2,width:width,height:height)
    }
}
