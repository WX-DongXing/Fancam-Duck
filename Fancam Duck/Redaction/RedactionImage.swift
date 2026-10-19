import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// A bounded, oriented PNG is embedded in the edit recipe, so projects remain self-contained.
/// Decode once per composition; never decode the sticker or read files on every video frame.
enum RedactionImage {
    static func prepare(_ data:Data) throws -> Data {
        guard let image=decode(data),
              let result=CFDataCreateMutable(kCFAllocatorDefault,0),
              let destination=CGImageDestinationCreateWithData(result,UTType.png.identifier as CFString,1,nil) else {throw RedactionError.incomplete}
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else {throw RedactionError.incomplete}
        return result as Data
    }
    /// Strip transparent padding once when loading, so modest scaling enlarges actual content.
    static func decode(_ data:Data) -> CGImage? {
        guard data.count<=30*1024*1024,let source=CGImageSourceCreateWithData(data as CFData,nil),
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                  kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:512] as CFDictionary) else {return nil}
        let width=image.width,height=image.height
        var bytes=[UInt8](repeating:0,count:width*height*4)
        let bounds=bytes.withUnsafeMutableBytes { buffer -> CGRect? in
            guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {return nil}
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            let pixels=buffer.bindMemory(to:UInt8.self)
            var left=width,top=height,right = -1,bottom = -1
            for y in 0..<height {for x in 0..<width where pixels[(y*width+x)*4+3]>8 {
                left=min(left,x);top=min(top,y);right=max(right,x);bottom=max(bottom,y)
            }}
            guard right>=left,bottom>=top else {return nil}
            return CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)
        }
        return bounds.flatMap {image.cropping(to:$0)}
    }

}
