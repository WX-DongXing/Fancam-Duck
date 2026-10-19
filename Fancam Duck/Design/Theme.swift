import SwiftUI

extension Color {
    static let acAccent = Color(red: 1, green: 0.79, blue: 0.25)
    static let acOnAccent = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let acBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.065, alpha: 1) : UIColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1) })
    static let acSurface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.115, alpha: 1) : .white })
    static let acStage = Color(white: 0.055)
    static let acTool = Color(white: 0.16)
}

struct PrimaryAction: View {
    let title: String
    var symbol = "arrow.right"
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.system(.body, weight: .semibold))
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            }.frame(maxWidth: .infinity).frame(minHeight: 56)
        }
        .buttonStyle(.plain)
        .background(disabled ? Color.primary.opacity(0.08) : Color.acAccent, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(disabled ? Color.secondary : Color.acOnAccent)
        .disabled(disabled)
        .sensoryFeedback(.selection, trigger: disabled)
        .accessibilityIdentifier("primaryAction")
    }
}

struct CameraButton: View {
    var title: String
    var symbol: String?
    var selected = false
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                if !title.isEmpty { Text(title).lineLimit(1) }
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 48)
            .background(selected ? Color.acAccent : Color.acTool, in: RoundedRectangle(cornerRadius: 14))
        }
        .foregroundStyle(selected ? Color.acOnAccent : .white)
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A quiet content layer, shared by the library, workspace and export preview.
struct StudioBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.21), Color(red: 0.045, green: 0.055, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// Glass belongs to controls, rather than video or project content.
struct StudioGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var selected = false
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: selected ? 0.30 : 0.19), in: shape)
        } else if #available(iOS 26, *) {
            let glass = selected ? Glass.clear.tint(.white.opacity(0.12)) : Glass.clear
            content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(selected ? 0.3 : 0.15), lineWidth: 0.5).allowsHitTesting(false) }
        }
    }
}

struct StudioGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else { content }
    }
}

/// Keep label content inside the native glass effect so the material cannot cover the text.
struct StudioGlassSelection: ViewModifier {
    let selected: Bool
    let namespace: Namespace.ID
    let selectionID: String
    let optionID: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background {
                if selected {Capsule().fill(.white.opacity(0.18)).matchedGeometryEffect(id:selectionID,in:namespace)}
            }
        } else if #available(iOS 26, *) {
            content.glassEffect(selected ? .regular.tint(.white.opacity(0.12)).interactive() : .identity,in:Capsule())
                .glassEffectID(selected ? selectionID : optionID,in:namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content.background {
                if selected {Capsule().fill(.thinMaterial).matchedGeometryEffect(id:selectionID,in:namespace)}
            }
        }
    }
}

struct StudioIcon: View {
    let symbol: String
    let label: String
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).symbolRenderingMode(.monochrome)
                .font(.system(size: 17, weight: .regular)).frame(width: 44, height: 44)
        }.buttonStyle(.plain).foregroundStyle(.white).frame(width: 44, height: 44)
            .contentShape(Circle()).modifier(StudioGlassSurface(shape: Circle(), selected: selected))
            .accessibilityLabel(label)
    }
}

struct StudioAction: View {
    let title: String
    var symbol = "chevron.right"
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                if !symbol.isEmpty { Image(systemName: symbol).font(.system(size: 16, weight: .medium)) }
            }.padding(.horizontal, 28).frame(minWidth: 190, minHeight: 50)
        }.buttonStyle(.plain).foregroundStyle(.white).frame(minWidth: 190, minHeight: 50)
            .contentShape(Capsule()).modifier(StudioGlassSurface(shape: Capsule(), selected: !disabled))
            .accessibilityLabel(title)
            .disabled(disabled).opacity(disabled ? 0.4 : 1)
            .accessibilityIdentifier("primaryAction")
    }
}
