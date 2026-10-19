import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Run from the repository root. The approved raster master remains the source of truth.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("docs/design-assets/logo-a1/app-icon-master.png")
let output = root.appendingPathComponent("Fancam Duck/Assets.xcassets/AppIcon.appiconset")
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { fatalError("Missing icon master") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var entries: [[String: String]] = []
func render(_ pixels: Int, mac: Bool) throws -> String {
    let filename = "\(mac ? "mac" : "ios")-\(pixels).png"
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)
        else { fatalError("Cannot create icon context") }
    context.interpolationQuality = .high
    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let rect = mac ? bounds.insetBy(dx: Double(pixels) * 0.1, dy: Double(pixels) * 0.1) : bounds
    if mac {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Double(pixels) * 0.18,
                              cornerHeight: Double(pixels) * 0.18, transform: nil))
        context.clip()
    }
    context.draw(image, in: rect)
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(filename) as CFURL,
              UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot write icon") }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finalize icon") }
    return filename
}
entries.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": try render(1024, mac: false)])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": try render(size * scale, mac: true)])
    }
}
let catalog: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
print("Generated iOS universal and all 10 macOS icon slots")

// A regular image set is required for in-app use; AppIcon is reserved for the launcher.
let brandOutput = root.appendingPathComponent("Fancam Duck/Assets.xcassets/BrandLogo.imageset")
try FileManager.default.createDirectory(at: brandOutput, withIntermediateDirectories: true)
try Data(contentsOf: output.appendingPathComponent("ios-1024.png"))
    .write(to: brandOutput.appendingPathComponent("BrandLogo.png"))
let brandCatalog: [String: Any] = [
    "images": [["idiom": "universal", "filename": "BrandLogo.png"]],
    "info": ["author": "xcode", "version": 1]
]
try JSONSerialization.data(withJSONObject: brandCatalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: brandOutput.appendingPathComponent("Contents.json"))
print("Generated in-app BrandLogo image set")
