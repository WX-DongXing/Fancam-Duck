import SwiftUI

/// Decorative beside the product name, avoiding duplicate VoiceOver announcements.
struct BrandLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}
