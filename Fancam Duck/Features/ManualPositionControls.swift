import SwiftUI

struct ManualPositionControls:View {
    @Binding var box:NormalizedRect?
    @Environment(\.scenePhase) private var scenePhase
    @State private var offset:CGSize = .zero
    @GestureState private var dragging=false
    private var moving:Bool {dragging && scenePhase == .active && box != nil && hypot(offset.width,offset.height)>1}

    var body:some View {
        VStack(spacing:12) {
            arrow("up",symbol:"chevron.up",dx:0,dy:-0.005)
            HStack(spacing:12) {
                arrow("left",symbol:"chevron.left",dx:-0.005,dy:0)
                joystick
                arrow("right",symbol:"chevron.right",dx:0.005,dy:0)
            }
            arrow("down",symbol:"chevron.down",dx:0,dy:0.005)
        }
        .disabled(box == nil)
        .task(id:moving) {
            guard moving else {return}
            let clock=ContinuousClock()
            var last=clock.now
            while !Task.isCancelled {
                do {try await Task.sleep(for:.milliseconds(20))} catch {return}
                guard moving,!Task.isCancelled else {return}
                let now=clock.now,elapsed=last.duration(to:now).components
                last=now
                let dt=min(0.05,Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18)
                move(dx:offset.width/16*dt*0.15,dy:offset.height/16*dt*0.15)
            }
        }
        .onChange(of:dragging) {_,active in if !active {offset = .zero}}
        .onChange(of:scenePhase) {_,phase in if phase != .active {offset = .zero}}
        .onDisappear {offset = .zero}
    }

    private var joystick:some View {
        Circle().fill(.thinMaterial)
            .overlay {Circle().stroke(.white.opacity(0.25),lineWidth:1)}
            .overlay {
                Circle().fill(Color.acAccent).frame(width:16,height:16)
                    .offset(x:offset.width*0.65,y:offset.height*0.65)
            }
            .frame(width:44,height:44).contentShape(Circle())
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.local)
                .updating($dragging) {_,active,_ in active=true}
                .onChanged {value in
                    let dx=value.translation.width,dy=value.translation.height
                    let length=max(16,hypot(dx,dy))
                    offset=CGSize(width:dx/length*16,height:dy/length*16)
                }.onEnded {_ in offset = .zero})
            .accessibilityElement().accessibilityLabel("按住并偏移，移动人物框")
            .accessibilityIdentifier("manualJoystick")
            .accessibilityAction(named:"向上移动") {move(dx:0,dy:-0.005)}
            .accessibilityAction(named:"向下移动") {move(dx:0,dy:0.005)}
            .accessibilityAction(named:"向左移动") {move(dx:-0.005,dy:0)}
            .accessibilityAction(named:"向右移动") {move(dx:0.005,dy:0)}
    }

    @ViewBuilder private func arrow(_ name:String,symbol:String,dx:Double,dy:Double)->some View {
        if #available(iOS 26.0, *) {
            button(name,symbol:symbol,dx:dx,dy:dy).buttonStyle(.glass).buttonBorderShape(.circle)
                .frame(width:44,height:44)
        } else {
            button(name,symbol:symbol,dx:dx,dy:dy).buttonStyle(.bordered).buttonBorderShape(.circle)
                .frame(width:44,height:44)
        }
    }
    private func button(_ name:String,symbol:String,dx:Double,dy:Double)->some View {
        Button {move(dx:dx,dy:dy)} label: {
            Image(systemName:symbol).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .accessibilityLabel(name == "up" ? "向上微调" : name == "down" ? "向下微调" : name == "left" ? "向左微调" : "向右微调")
        .accessibilityIdentifier("manualNudge-"+name)
    }
    private func move(dx:Double,dy:Double) {
        guard let box else {return}
        var transaction=Transaction(animation:nil);transaction.disablesAnimations=true
        withTransaction(transaction) {self.box=ManualBoxGeometry.move(box,dx:dx,dy:dy)}
    }
}
