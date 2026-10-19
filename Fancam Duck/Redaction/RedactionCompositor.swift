import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Immutable render recipe, shared by the source viewport, output preview and actual export.
final class RedactionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let sourceSize: CGSize
    let outputSize: CGSize
    let sourceStart: Double
    let crops: [CropPlan.Frame]
    let plan: RedactionPlan
    let strength: Double
    let style: RedactionSettings.Style
    let sticker: CIImage?
    init(trackID: CMPersistentTrackID, range: CMTimeRange, transform: CGAffineTransform, source: CGSize, output: CGSize,
         start: Double, crops: [CropPlan.Frame], plan: RedactionPlan, strength: Double, style: RedactionSettings.Style, sticker: CIImage?) {
        self.trackID=trackID; timeRange=range; requiredSourceTrackIDs=[NSNumber(value:trackID)]
        self.transform=transform;sourceSize=source;outputSize=output;sourceStart=start;self.crops=crops;self.plan=plan;self.strength=strength;self.style=style;self.sticker=sticker
    }
}

final class RedactionCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: Any]? = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                                                     kCVPixelBufferMetalCompatibilityKey as String:true]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                                                                      kCVPixelBufferMetalCompatibilityKey as String:true]
    private let queue = DispatchQueue(label:"com.fancamduck.redaction-render",qos:.userInitiated)
    // Decode and encode already agree on Rec.709 display RGB. A second CI working-space
    // conversion changes even untouched pixels; keep this video pipeline in that same space.
    private let context = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let recipe=request.videoCompositionInstruction as? RedactionInstruction,
                      let source=request.sourceFrame(byTrackID:recipe.trackID),let destination=request.renderContext.newPixelBuffer() else {
                    request.finish(with:RedactionError.incomplete);return
                }
                let image=CIImage(cvPixelBuffer:source,options:[.colorSpace:NSNull()]).transformed(by:recipe.transform)
                let time=request.compositionTime.seconds+recipe.sourceStart
                let crop=CropPlan.rect(at:time,in:recipe.crops) ?? CGRect(origin:.zero,size:recipe.sourceSize)
                let result=RedactionRenderer.render(image,source:recipe.sourceSize,crop:crop,output:recipe.outputSize,
                                                    boxes:recipe.plan.rectangles(at:time),strength:recipe.strength,style:recipe.style,sticker:recipe.sticker,region:recipe.plan.region)
                CVBufferSetAttachment(destination,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
                CVBufferSetAttachment(destination,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
                CVBufferSetAttachment(destination,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
                context.render(result,to:destination,bounds:CGRect(origin:.zero,size:recipe.outputSize),colorSpace:nil)
                request.finish(withComposedVideoFrame:destination)
            }
        }
    }
    func cancelAllPendingVideoCompositionRequests() {
        // Drain requests in order. Never reuse mutable instructions or CI filters across requests.
        queue.sync {}
    }
}

enum RedactionRenderer {
    /// Crop first, shade only at output resolution. Masks stay in upright source coordinates.
    static func render(_ upright: CIImage, source: CGSize, crop: CGRect, output: CGSize,
                       boxes: [NormalizedRect], strength: Double, style: RedactionSettings.Style = .frosted, sticker: CIImage? = nil, region: RedactionSettings.Region = .face) -> CIImage {
        let scale=output.width/crop.width
        let origin=CGPoint(x:crop.minX,y:source.height-crop.maxY)
        let transform=CGAffineTransform(translationX:-origin.x,y:-origin.y).concatenating(.init(scaleX:scale,y:scale))
        let extent=CGRect(origin:.zero,size:output)
        let transformed=upright.transformed(by:transform)
        let original=transformed.cropped(to:extent)
        var result=original
        // A source-anchored grid and constant block size prevent texture crawling as boxes move.
        let sourceBlock=max(6,max(source.width,source.height)*(0.003+min(1,max(0,strength))*0.007))
        let block=sourceBlock*scale
        let base:CIImage
        switch style {
        case .mosaic:
            let pixel=CIFilter.pixellate();pixel.inputImage=transformed.clampedToExtent();pixel.scale=Float(block)
            pixel.center=CGPoint(x:-origin.x*scale,y:-origin.y*scale)
            base=pixel.outputImage?.cropped(to:extent) ?? CIImage(color:.black).cropped(to:extent)
        case .frosted:
            base=transformed.clampedToExtent().applyingGaussianBlur(sigma:max(10,sourceBlock*1.6)*scale)
                .applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0.65,kCIInputBrightnessKey:0.025]).cropped(to:extent)
        case .image:
            // Image mode uses only the supplied pixels and alpha, without an external backing.
            base=original
        }
        for box in boxes {
            let rect=CGRect(x:box.x*source.width,y:(1-box.y-box.height)*source.height,width:box.width*source.width,height:box.height*source.height).applying(transform)
            guard rect.intersects(extent) else { continue }
            if style == .image,let sticker {
                // Fill with a small, fixed overscan. Transparent image edges retain their own shape;
                // no generated backing, blurred outline or shadow is composited behind the sticker.
                let coverage=rect
                let fit=max(coverage.width/sticker.extent.width,coverage.height/sticker.extent.height)*1.12
                let fitted=sticker.transformed(by:.init(translationX:-sticker.extent.minX,y:-sticker.extent.minY))
                    .transformed(by:.init(scaleX:fit,y:fit))
                    .transformed(by:.init(translationX:coverage.midX-sticker.extent.width*fit/2,y:coverage.midY-sticker.extent.height*fit/2))
                result=fitted.cropped(to:coverage).composited(over:result).cropped(to:extent)
                continue
            }
            let shape=CIFilter.roundedRectangleGenerator();shape.extent=rect;shape.radius=Float(min(rect.width,rect.height)*(region == .face ? 0.45 : 0.10))
            shape.color=CIColor.white
            guard let generated=shape.outputImage else { continue }
            // Light proportional feathering stays inside the conservative coverage margin.
            let mask=generated.composited(over:CIImage(color:.black).cropped(to:extent)).applyingGaussianBlur(sigma:max(0.65,min(rect.width,rect.height)*0.025)).cropped(to:extent)
            let blend=CIFilter.blendWithMask();blend.inputImage=base;blend.backgroundImage=result;blend.maskImage=mask
            if let image=blend.outputImage { result=image.cropped(to:extent) }
        }
        return result
    }
    static func composition(trackID:CMPersistentTrackID,range:CMTimeRange,transform:CGAffineTransform,source:CGSize,
                            output:CGSize,start:Double,crops:[CropPlan.Frame],plan:RedactionPlan,strength:Double,rate:Double,style:RedactionSettings.Style = .frosted,imageData:Data? = nil) -> AVMutableVideoComposition {
        let video=AVMutableVideoComposition()
        video.customVideoCompositorClass=RedactionCompositor.self
        video.renderSize=output;video.frameDuration=CMTime(seconds:1/max(1,min(60,rate)),preferredTimescale:60000)
        video.instructions=[RedactionInstruction(trackID:trackID,range:range,transform:transform,source:source,output:output,start:start,crops:crops,plan:plan,strength:strength,style:style,sticker:imageData.flatMap {RedactionImage.decode($0)}.map {CIImage(cgImage:$0)})]
        return video
    }
}
