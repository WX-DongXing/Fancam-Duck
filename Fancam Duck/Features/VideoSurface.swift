import SwiftUI
import AVFoundation

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView { let view = PlayerUIView(); view.playerLayer.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: PlayerUIView, context: Context) {
        // Reassigning the same player can invalidate the displayed frame during layout animation.
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct DemoStage: View {
    var time: Double
    var target: Int?
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 360
            var c = context
            c.scaleBy(x: scale, y: scale)
            let height = size.height / scale
            c.fill(Path(CGRect(x: 0, y: 0, width: 360, height: height)), with: .color(Color(red: 0.13, green: 0.22, blue: 0.23)))
            let floor = height * 0.74
            c.fill(Path(CGRect(x: 0, y: floor, width: 360, height: height - floor)), with: .color(Color(red: 0.58, green: 0.59, blue: 0.50)))
            for column in 0..<5 {
                c.stroke(Path(CGRect(x: Double(column) * 74 + 4, y: 18, width: 70, height: floor - 22)), with: .color(.white.opacity(0.12)), lineWidth: 0.7)
            }
            for y in stride(from: floor + 10, through: height, by: 13) {
                var path = Path(); path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: 360, y: y))
                c.stroke(path, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
            }
            for index in 0..<4 {
                let x = 57 + Double(index) * 82 + sin(time * 0.65 + Double(index) * 0.2) * 7
                let y = floor - 93 - Double(index % 2) * 5
                let wave = sin(time * 0.65 + Double(index) * 0.3)
                let shirts: [Color] = [.init(red: 0.8, green: 0.79, blue: 0.7), .init(red: 0.48, green: 0.67, blue: 0.57), .init(red: 0.67, green: 0.64, blue: 0.57), .init(red: 0.66, green: 0.72, blue: 0.71)]
                func limb(_ points: [CGPoint], color: Color, width: Double) {
                    var path = Path(); for (i, point) in points.enumerated() { let point = CGPoint(x: x + point.x, y: y + point.y); if i == 0 { path.move(to: point) } else { path.addLine(to: point) } }
                    c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
                limb([CGPoint(x: -6, y: 50), CGPoint(x: -15 - wave * 5, y: 70), CGPoint(x: -24, y: 91)], color: .init(white: 0.14), width: 10)
                limb([CGPoint(x: 7, y: 50), CGPoint(x: 18 + wave * 6, y: 72), CGPoint(x: 30, y: 91)], color: .init(white: 0.14), width: 10)
                limb([CGPoint(x: -27, y: 93), CGPoint(x: -17, y: 93)], color: .init(white: 0.9), width: 4)
                limb([CGPoint(x: 27, y: 93), CGPoint(x: 37, y: 93)], color: .init(white: 0.9), width: 4)
                limb([CGPoint(x: -9, y: 14), CGPoint(x: -25, y: 26 - wave * 14), CGPoint(x: -36, y: 12 - wave * 20)], color: shirts[index], width: 8)
                limb([CGPoint(x: 10, y: 14), CGPoint(x: 24, y: 23 + wave * 11), CGPoint(x: 37, y: 8 + wave * 19)], color: shirts[index], width: 8)
                let torso = CGRect(x: x - 12, y: y + 9, width: 25, height: 43)
                c.fill(Path(roundedRect: torso, cornerRadius: 4), with: .color(shirts[index]))
                c.fill(Path(ellipseIn: CGRect(x: x - 8, y: y - 16, width: 16, height: 24)), with: .color(.init(red: 0.76, green: 0.64, blue: 0.53)))
                c.fill(Path(roundedRect: CGRect(x: x - 9, y: y - 18, width: 18, height: 8), cornerRadius: 4), with: .color(.init(white: 0.10)))
                if target == index { c.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 29, width: 4, height: 4)), with: .color(.acAccent)) }
            }
        }.accessibilityLabel("四名舞者的动作示意，演示素材")
    }
    static func body(index: Int, time: Double) -> NormalizedRect {
        let x = (57 + Double(index) * 82 + sin(time * 0.65 + Double(index) * 0.2) * 7 - 39) / 360
        return NormalizedRect(x: max(0, min(0.78, x)), y: index % 2 == 0 ? 0.14 : 0.115, width: 0.215, height: 0.65)
    }
}
