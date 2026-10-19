import SwiftUI
import UIKit

/// A native segmented control with a real 48-point control surface, not just outer padding.
struct NativeSegmentedControl<Selection: Hashable>: UIViewRepresentable {
    let title: String
    let options: [Selection]
    @Binding var selection: Selection
    let label: (Selection) -> String
    var symbol: ((Selection) -> String)? = nil
    var height: CGFloat = 48
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control=UISegmentedControl(items:options.map(label))
        applySymbols(to:control)
        control.addTarget(context.coordinator,action:#selector(Coordinator.changed(_:)),for:.valueChanged)
        control.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent=self
        let titles=options.map(label)
        if control.numberOfSegments != titles.count || (symbol == nil && titles.indices.contains(where:{control.titleForSegment(at:$0) != titles[$0]})) {
            control.removeAllSegments()
            for (index,title) in titles.enumerated() {control.insertSegment(withTitle:title,at:index,animated:false)}
            applySymbols(to:control)
        }
        control.selectedSegmentIndex=options.firstIndex(of:selection) ?? UISegmentedControl.noSegment
        control.isEnabled=isEnabled
        control.accessibilityLabel=title
        let font=UIFont.preferredFont(forTextStyle:.subheadline)
        control.setTitleTextAttributes([.font:font],for:.normal)
    }

    private func applySymbols(to control:UISegmentedControl) {
        guard let symbol else {return}
        // UISegmentedControl displays either a title or an image. Combine both into a template
        // image so the system still draws its native tracking, selection and disabled states.
        for (index,option) in options.enumerated() {
            let title=label(option)
            let font=UIFont.preferredFont(forTextStyle:.caption2)
            let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:UIColor.black]
            let textSize=(title as NSString).size(withAttributes:attributes)
            let icon=UIImage(systemName:symbol(option),withConfiguration:UIImage.SymbolConfiguration(pointSize:18,weight:.regular))
            let width=max(28,textSize.width)
            let format=UIGraphicsImageRendererFormat()
            format.scale=displayScale
            let image=UIGraphicsImageRenderer(size:CGSize(width:width,height:38),format:format).image { _ in
                icon?.withTintColor(.black,renderingMode:.alwaysOriginal)
                    .draw(in:CGRect(x:(width-20)/2,y:0,width:20,height:20))
                (title as NSString).draw(at:CGPoint(x:(width-textSize.width)/2,y:23),withAttributes:attributes)
            }.withRenderingMode(.alwaysTemplate)
            image.accessibilityLabel=title
            control.setImage(image,forSegmentAt:index)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? uiView.intrinsicContentSize.width,height:height)
    }

    final class Coordinator: NSObject {
        var parent: NativeSegmentedControl
        init(_ parent: NativeSegmentedControl) {self.parent=parent}
        @objc func changed(_ control: UISegmentedControl) {
            guard parent.options.indices.contains(control.selectedSegmentIndex) else {return}
            parent.selection=parent.options[control.selectedSegmentIndex]
            // A model may reject a change during a gesture; keep native and model selection aligned.
            control.selectedSegmentIndex=parent.options.firstIndex(of:parent.selection) ?? UISegmentedControl.noSegment
        }
    }
}
