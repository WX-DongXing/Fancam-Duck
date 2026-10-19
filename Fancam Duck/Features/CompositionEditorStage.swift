import SwiftUI
import AVFoundation

/// The output viewport is shared with CropPlan; surrounding phone chrome is never exported.
struct CompositionVideoViewport: View {
    @Bindable var model: AppModel
    let source: CGSize
    let viewport: CGSize
    let composition: Bool
    var body: some View {
        let crop=composition ? model.compositionCrop ?? CGRect(origin:.zero,size:source) : CGRect(origin:.zero,size:source)
        let scale=viewport.width/max(1,crop.width)
        ZStack(alignment:.topLeading) {
            Color.black
            // Keep the source surface at the same structural identity through tool and aspect changes.
            sourceContent.frame(width:source.width*scale,height:source.height*scale)
                .offset(x:-crop.minX*scale,y:-crop.minY*scale)
                .opacity(composition && model.isPlaying ? 0 : 1)
            if let player=model.previewPlayer {
                PlayerSurface(player:player).frame(width:viewport.width,height:viewport.height)
                    .opacity(composition && model.isPlaying ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            if composition {
                if model.compositionAdjusting {
                    Path { path in
                        for fraction in [1.0/3,2.0/3] {
                            path.move(to:.init(x:viewport.width*fraction,y:0))
                            path.addLine(to:.init(x:viewport.width*fraction,y:viewport.height))
                            path.move(to:.init(x:0,y:viewport.height*fraction))
                            path.addLine(to:.init(x:viewport.width,y:viewport.height*fraction))
                        }
                    }.stroke(.white.opacity(0.5),lineWidth:0.5).allowsHitTesting(false)
                }
                CompositionGestureSurface(enabled:model.compositionEditing && model.settingsEnabled && !model.redactionEditing && !model.compositionBusy && !model.isPlaying,
                    crop:{model.compositionCrop ?? .zero},begin:{model.beginCompositionGesture()},
                    change:{model.applyCompositionCrop($0)},end:{model.endCompositionGesture(cancelled:$0)},
                    value:"\(model.project?.settings.compositionScale ?? 1),\(model.project?.settings.compositionX ?? 0),\(model.project?.settings.compositionY ?? 0)")
                    .frame(width:viewport.width,height:viewport.height)
                    .accessibilityAction(named:"放大") {model.compositionZoom(1.1)}
                    .accessibilityAction(named:"缩小") {model.compositionZoom(1/1.1)}
                    .accessibilityAction(named:"向左移动") {model.compositionMove(x:-0.03,y:0)}
                    .accessibilityAction(named:"向右移动") {model.compositionMove(x:0.03,y:0)}
            }
        }.frame(width:viewport.width,height:viewport.height,alignment:.topLeading)
            .contentShape(Rectangle()).clipped()
            .overlay {
                if composition {Rectangle().stroke(.white.opacity(0.35),lineWidth:1).allowsHitTesting(false)}
            }
    }
    private var sourceContent: some View {
        Group {
            if model.isDemo { DemoStage(time: model.currentTime, target: nil) }
            else if let preview=model.processingPreview {Image(decorative:preview,scale:1).resizable().scaledToFit()}
            else if let player = model.player { PlayerSurface(player: player) }
            else { Color.black }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct CompositionGestureSurface:UIViewRepresentable {
    var enabled:Bool
    var crop:()->CGRect
    var begin:()->Void
    var change:(CGRect)->Void
    var end:(Bool)->Void
    var value:String
    func makeUIView(context:Context) -> GestureView {let view=GestureView();view.bind(self);return view}
    func updateUIView(_ view:GestureView,context:Context) {view.bind(self)}
    final class GestureView:UIView,UIGestureRecognizerDelegate {
        private var callbacks:CompositionGestureSurface?
        private var active=Set<ObjectIdentifier>()
        private var base=CGRect.zero
        private var anchor=CGPoint(x:0.5,y:0.5)
        private lazy var pan=UIPanGestureRecognizer(target:self,action:#selector(handle(_:)))
        private lazy var pinch=UIPinchGestureRecognizer(target:self,action:#selector(handle(_:)))
        override init(frame:CGRect) {
            super.init(frame:frame);backgroundColor = .clear
            pan.maximumNumberOfTouches=2;pan.delegate=self;pinch.delegate=self
            addGestureRecognizer(pan);addGestureRecognizer(pinch)
            isAccessibilityElement=true;accessibilityIdentifier="compositionCanvas";accessibilityLabel="构图画面"
        }
        required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
        func bind(_ value:CompositionGestureSurface) {callbacks=value;accessibilityValue=value.value}
        override func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer) -> Bool {callbacks?.enabled == true}
        func gestureRecognizer(_ a:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith b:UIGestureRecognizer) -> Bool {a.view===self && b.view===self}
        private func rebase() {
            base=callbacks?.crop() ?? .zero;pan.setTranslation(.zero,in:self);pinch.scale=1
            let point=pinch.numberOfTouches>=2 ? pinch.location(in:self) : .init(x:bounds.midX,y:bounds.midY)
            anchor = .init(x:point.x/max(1,bounds.width),y:point.y/max(1,bounds.height))
        }
        @objc private func handle(_ recognizer:UIGestureRecognizer) {
            let id=ObjectIdentifier(recognizer)
            switch recognizer.state {
            case .began:
                if active.isEmpty {callbacks?.begin()};active.insert(id);rebase()
            case .changed:
                callbacks?.change(CompositionGeometry.transformed(base,scale:Double(pinch.scale),translation:CGSize(width:pan.translation(in:self).x,height:pan.translation(in:self).y),anchor:anchor,viewport:bounds.size))
            case .ended,.cancelled,.failed:
                guard active.contains(id) else {return}
                active.remove(id)
                if active.isEmpty {callbacks?.end(recognizer.state != .ended)} else {rebase()}
            default:break
            }
        }
    }
}
