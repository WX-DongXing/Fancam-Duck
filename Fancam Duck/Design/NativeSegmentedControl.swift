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
        let control=UISegmentedControl()
        control.addTarget(context.coordinator,action:#selector(Coordinator.changed(_:)),for:.valueChanged)
        control.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        updateControl(control,coordinator:context.coordinator)
    }

    func updateControl(_ control:UISegmentedControl,coordinator:Coordinator) {
        coordinator.parent=self
        let titles=options.map(label),symbols=symbol.map {renderer in options.map(renderer)}
        let font=UIFont.preferredFont(forTextStyle:.subheadline)
        if coordinator.renderedOptions != options || coordinator.renderedTitles != titles ||
            coordinator.renderedSymbols != symbols || coordinator.renderedScale != displayScale ||
            (symbol != nil && coordinator.renderedFont != font) {
            control.removeAllSegments()
            for (index,title) in titles.enumerated() {control.insertSegment(withTitle:title,at:index,animated:false)}
            applySymbols(to:control)
            coordinator.renderedOptions=options;coordinator.renderedTitles=titles
            coordinator.renderedSymbols=symbols;coordinator.renderedScale=displayScale
        }
        let selected=options.firstIndex(of:selection) ?? UISegmentedControl.noSegment
        // Repeated writes restart UIKit's selection feedback during unrelated model updates.
        if control.selectedSegmentIndex != selected {control.selectedSegmentIndex=selected}
        if control.isEnabled != isEnabled {control.isEnabled=isEnabled}
        if control.accessibilityLabel != title {control.accessibilityLabel=title}
        if coordinator.renderedFont != font {
            control.setTitleTextAttributes([.font:font],for:.normal)
            coordinator.renderedFont=font
        }
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
        var renderedOptions:[Selection]?
        var renderedTitles:[String]?
        var renderedSymbols:[String]?
        var renderedScale:CGFloat?
        var renderedFont:UIFont?
        init(_ parent: NativeSegmentedControl) {self.parent=parent}
        @objc func changed(_ control: UISegmentedControl) {
            guard parent.options.indices.contains(control.selectedSegmentIndex) else {return}
            parent.selection=parent.options[control.selectedSegmentIndex]
            // SwiftUI reconciles an accepted/rejected value on the next render. Reading
            // this render's binding here can still return the old selection and undo the tap.
        }
    }
}
