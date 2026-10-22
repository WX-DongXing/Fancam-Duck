import SwiftUI

/// Keep drag updates local so moving the sheet does not redraw the video workspace.
struct PreviewSettingsSheet<Content:View>:View {
    let animation:Animation?
    var allowsContentDismissal=true
    let onDismiss:()->Void
    @ViewBuilder var content:Content
    @State private var dragOffset:CGFloat=0

    var body:some View {
        VStack(spacing:0) {
            Capsule().fill(.secondary).frame(width:36,height:4)
                .frame(maxWidth:.infinity).frame(height:28).contentShape(Rectangle())
                .gesture(sheetDrag.exclusively(before:TapGesture().onEnded {dismiss()}))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {dismiss()}
                .accessibilityLabel("收起设置")
                .accessibilityIdentifier("previewPanelClose")
            content
        }
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:24))
        .overlay {RoundedRectangle(cornerRadius:24).strokeBorder(.white.opacity(0.1))}
        .offset(y:dragOffset)
        .simultaneousGesture(sheetDrag,including:allowsContentDismissal ? .all : .subviews)
        .accessibilityAction(.escape) {dismiss()}
    }

    private var sheetDrag:some Gesture {
        DragGesture(minimumDistance:15,coordinateSpace:.global)
            .onChanged {value in
                guard value.translation.height>abs(value.translation.width) else {return}
                var transaction=Transaction(animation:nil)
                transaction.disablesAnimations=true
                withTransaction(transaction) {dragOffset=value.translation.height}
            }
            .onEnded {value in
                if value.translation.height>abs(value.translation.width),
                   value.translation.height>40 || value.predictedEndTranslation.height>100 {
                    // Retain the dragged position and full content until the exit transition ends.
                    dismiss()
                } else {
                    withAnimation(animation) {dragOffset=0}
                }
            }
    }

    private func dismiss() {
        withAnimation(animation) {onDismiss()}
    }
}
