import UIKit

/// Built-in transparent stickers are embedded as PNG data in the project recipe.
/// Preview and export therefore use the same pixels, including after reopening.
enum RedactionSticker: String, CaseIterable, Identifiable {
    case duck, cat, star, alien
    var id: String {rawValue}
    var title: String {
        switch self {case .duck: "直拍鸭"; case .cat: "猫咪"; case .star: "星星"; case .alien: "外星人"}
    }
    @MainActor private static let images: [Self:UIImage] = Dictionary(uniqueKeysWithValues:allCases.compactMap {sticker in
        sticker.makeImage().map {(sticker,$0)}
    })
    @MainActor private static let imageData: [Self:Data] = images.compactMapValues {$0.pngData()}
    @MainActor var image: UIImage? {Self.images[self]}
    @MainActor private func makeImage() -> UIImage? {
        if self == .duck {return UIImage(named:"DuckSticker")}
        let format=UIGraphicsImageRendererFormat();format.opaque=false;format.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:256,height:256),format:format).image { _ in
            func ellipse(_ rect:CGRect,_ color:UIColor) {color.setFill();UIBezierPath(ovalIn:rect).fill()}
            func polygon(_ points:[CGPoint],_ color:UIColor) {
                let path=UIBezierPath();path.move(to:points[0]);for point in points.dropFirst() {path.addLine(to:point)}
                path.close();color.setFill();path.fill()
            }
            switch self {
            case .duck: break
            case .cat:
                let orange=UIColor(red:1,green:0.66,blue:0.25,alpha:1)
                polygon([.init(x:26,y:100),.init(x:22,y:22),.init(x:100,y:64)],orange)
                polygon([.init(x:156,y:64),.init(x:234,y:22),.init(x:230,y:100)],orange)
                ellipse(CGRect(x:18,y:54,width:220,height:184),orange)
                ellipse(CGRect(x:62,y:116,width:22,height:34),.black)
                ellipse(CGRect(x:172,y:116,width:22,height:34),.black)
                polygon([.init(x:112,y:162),.init(x:144,y:162),.init(x:128,y:180)],.systemPink)
                ellipse(CGRect(x:36,y:163,width:35,height:17),.systemPink.withAlphaComponent(0.65))
                ellipse(CGRect(x:185,y:163,width:35,height:17),.systemPink.withAlphaComponent(0.65))
            case .star:
                let points=(0..<10).map {index -> CGPoint in
                    let angle=Double(index)*Double.pi/5-Double.pi/2
                    let radius=Double(index.isMultiple(of:2) ? 122 : 69)
                    return CGPoint(x:128+cos(angle)*radius,y:134+sin(angle)*radius)
                }
                polygon(points,.systemYellow)
                ellipse(CGRect(x:89,y:112,width:16,height:28),.black)
                ellipse(CGRect(x:151,y:112,width:16,height:28),.black)
                ellipse(CGRect(x:115,y:158,width:26,height:15),.systemOrange)
            case .alien:
                ellipse(CGRect(x:20,y:15,width:216,height:221),.systemMint)
                ellipse(CGRect(x:47,y:95,width:64,height:77),.init(red:0.17,green:0.1,blue:0.3,alpha:1))
                ellipse(CGRect(x:145,y:95,width:64,height:77),.init(red:0.17,green:0.1,blue:0.3,alpha:1))
                ellipse(CGRect(x:64,y:107,width:15,height:20),.white)
                ellipse(CGRect(x:162,y:107,width:15,height:20),.white)
                ellipse(CGRect(x:110,y:194,width:36,height:10),.black)
            }
        }
    }
    @MainActor var data: Data? {Self.imageData[self]}
}
