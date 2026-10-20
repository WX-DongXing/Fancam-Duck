import SwiftUI

/// Content requirements, rather than a device name, determine when the controls can sit beside
/// the canvas. AnyLayout preserves the player and editor state while the window changes shape.
enum WorkspaceLayout {
    static let panelWidth:CGFloat=360
    static let minimumCanvasWidth:CGFloat=360
    static let spacing:CGFloat=20
    static func usesColumns(in size:CGSize) -> Bool {
        size.width>=minimumCanvasWidth+panelWidth+spacing && size.height>=440
    }
}

struct WorkspaceArrangement<Canvas:View,Controls:View>:View {
    let size:CGSize
    @ViewBuilder var canvas:Canvas
    @ViewBuilder var controls:Controls
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var columns:Bool {WorkspaceLayout.usesColumns(in:size)}
    @ViewBuilder var body:some View {
        // Availability checks cannot hide unknown symbols from an older SDK.
        #if FANCAM_DUCK_NATIVE_ARRANGEMENT && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1,*),horizontalSizeClass == .regular {
            ArrangementView {
                canvas.frame(maxWidth:.infinity,maxHeight:.infinity)
                    .splitArrangementLayoutRatio(idealHorizontal:0.66,idealVertical:0.62)
            } secondary: {
                controls.frame(maxWidth:.infinity,maxHeight:.infinity)
                    .splitArrangementLayoutSize(idealWidth:320,idealHeight:300)
                    .padding(12)
            }.arrangementViewStyle(.split)
                .accessibilityElement(children:.contain).accessibilityIdentifier("workspaceArrangement")
        } else {fallback}
        #else
        fallback
        #endif
    }
    private var fallback:some View {
        let layout=columns ? AnyLayout(HStackLayout(alignment:.center,spacing:WorkspaceLayout.spacing)) : AnyLayout(VStackLayout(spacing:0))
        return layout {
            canvas.frame(maxWidth:.infinity,maxHeight:.infinity)
            controls
                .frame(width:columns ? WorkspaceLayout.panelWidth : nil)
                .frame(maxHeight:columns ? .infinity : nil,alignment:.bottom)
                .padding(.trailing,columns ? 18 : 0)
        }.accessibilityElement(children:.contain).accessibilityIdentifier(columns ? "workspaceColumns" : "workspaceStack")
    }
}

#if targetEnvironment(macCatalyst)
/// Configure this window only, without consulting global screen geometry.
struct DesktopWindowConfiguration:UIViewRepresentable {
    func makeUIView(context:Context) -> WindowView {WindowView()}
    func updateUIView(_ uiView:WindowView,context:Context) {}
    final class WindowView:UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.windowScene?.sizeRestrictions?.minimumSize=CGSize(width:720,height:560)
        }
    }
}
#endif

#if targetEnvironment(macCatalyst)
/// Desktop chrome is deliberately quiet: content panes carry hierarchy, not oversized buttons.
enum DesktopPalette {
    static let background = Color(red:0.065,green:0.071,blue:0.082)
    static let panel = Color(red:0.105,green:0.113,blue:0.129)
    static let raised = Color(red:0.145,green:0.155,blue:0.175)
    static let border = Color.white.opacity(0.085)
}
struct DesktopButtonStyle:ButtonStyle {
    var prominent=false
    var height:CGFloat=44
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.medium))
            .padding(.horizontal,14).frame(minHeight:height).contentShape(Capsule())
            .foregroundStyle(.white)
            .modifier(StudioGlassSurface(shape:Capsule(),selected:prominent))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct DesktopSection<Content:View>:View {
    let title:String
    @ViewBuilder var content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            content
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct DesktopFact:View {
    let title:String
    let value:String
    var body:some View {
        HStack {Text(title).foregroundStyle(.secondary);Spacer();Text(value).lineLimit(1)}
            .font(.system(size:12)).padding(.vertical,4)
    }
}
#endif
