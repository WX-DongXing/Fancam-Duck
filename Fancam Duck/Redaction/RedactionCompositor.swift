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
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                                                     kCVPixelBufferMetalCompatibilityKey as String:true]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
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
        // The UI range 0...100 now spans the previous physical strength 0...30%.
        let amount=RedactionSettings.renderStrength(strength)
        if style != .image && amount == 0 {return original}
        let lowStrengthRamp=min(1,amount/0.3)
        // A source-anchored grid and constant block size prevent texture crawling as boxes move.
        let sourceBlock=max(6,max(source.width,source.height)*(0.003+amount*0.007))
        let block=sourceBlock*scale*lowStrengthRamp
        let base:CIImage
        switch style {
        case .mosaic:
            let pixel=CIFilter.pixellate();pixel.inputImage=transformed.clampedToExtent();pixel.scale=Float(block)
            pixel.center=CGPoint(x:-origin.x*scale,y:-origin.y*scale)
            base=pixel.outputImage?.cropped(to:extent) ?? CIImage(color:.black).cropped(to:extent)
        case .frosted:
            // Radius is evaluated per subject below, rather than from the full video size.
            base=original
        case .image:
            // Image mode uses only the supplied pixels and alpha, without an external backing.
            base=original
        }
        for box in boxes {
            let rect=CGRect(x:box.x*source.width,y:(1-box.y-box.height)*source.height,width:box.width*source.width,height:box.height*source.height).applying(transform)
            guard rect.intersects(extent) else { continue }
            if style == .image,let sticker {
                // Keep the complete artwork inside the tracked coverage. Aspect-fill plus
                // overscan used to enlarge the face graphic and then cut off its features.
                let coverage=rect
                let fit=min(coverage.width/sticker.extent.width,coverage.height/sticker.extent.height)
                let fitted=sticker.transformed(by:.init(translationX:-sticker.extent.minX,y:-sticker.extent.minY))
                    .transformed(by:.init(scaleX:fit,y:fit))
                    .transformed(by:.init(translationX:coverage.midX-sticker.extent.width*fit/2,y:coverage.midY-sticker.extent.height*fit/2))
                result=fitted.composited(over:result).cropped(to:extent)
                continue
            }
            let shortSide=min(rect.width,rect.height)
            let mask:CIImage
            let obscured:CIImage
            if style == .frosted {
                // Preserve a broad core. Gradually reduce the blur radius at the boundary,
                // rather than shrinking and fading a uniformly blurred cutout.
                mask=frostedMask(in:rect,region:region).composited(over:CIImage(color:.black).cropped(to:extent)).cropped(to:extent)
                let sigma=max(1.5*scale,shortSide*(0.055+amount*0.125))*lowStrengthRamp
                let variable=CIFilter.maskedVariableBlur()
                variable.inputImage=transformed.clampedToExtent().cropped(to:rect.insetBy(dx:-sigma*3,dy:-sigma*3))
                variable.mask=mask
                variable.radius=Float(sigma)
                obscured=(variable.outputImage ?? original).cropped(to:rect)
            } else {
                let feather=max(0.35*scale,shortSide*0.025)
                let inset=min(shortSide*0.15,feather*2)
                let shape=CIFilter.roundedRectangleGenerator();shape.extent=rect.insetBy(dx:inset,dy:inset)
                shape.radius=Float(max(0,shortSide*(region == .face ? 0.45 : 0.10)-inset));shape.color=CIColor.white
                guard let generated=shape.outputImage else {continue}
                mask=generated.applyingGaussianBlur(sigma:feather).cropped(to:rect)
                    .composited(over:CIImage(color:.black).cropped(to:extent)).cropped(to:extent)
                obscured=base
            }
            let blend=CIFilter.blendWithMask();blend.inputImage=obscured;blend.backgroundImage=result;blend.maskImage=mask
            if let image=blend.outputImage { result=image.cropped(to:extent) }
        }
        return result
    }
    /// Full-size head envelope, or a broad body core with smooth transitions on all four sides.
    /// Both reach zero at the boundary, so no mask is cut off at a nonzero opacity.
    static func frostedMask(in rect:CGRect,region:RedactionSettings.Region) -> CIImage {
        if region == .face {
            let radial=CIFilter.radialGradient()
            radial.center = .zero;radial.radius0=0.8;radial.radius1=1
            radial.color0 = .white;radial.color1 = .black
            return (radial.outputImage ?? CIImage(color:.black))
                .transformed(by:CGAffineTransform(scaleX:rect.width/2,y:rect.height/2)
                    .concatenating(.init(translationX:rect.midX,y:rect.midY))).cropped(to:rect)
        }
        let transition=min(rect.width,rect.height)*0.14
        let edges:[(CGPoint,CGPoint)]=[
            (.init(x:rect.minX,y:rect.midY),.init(x:rect.minX+transition,y:rect.midY)),
            (.init(x:rect.maxX,y:rect.midY),.init(x:rect.maxX-transition,y:rect.midY)),
            (.init(x:rect.midX,y:rect.minY),.init(x:rect.midX,y:rect.minY+transition)),
            (.init(x:rect.midX,y:rect.maxY),.init(x:rect.midX,y:rect.maxY-transition))
        ]
        return edges.reduce(CIImage(color:.white).cropped(to:rect)) { mask,edge in
            let gradient=CIFilter.smoothLinearGradient()
            gradient.point0=edge.0;gradient.point1=edge.1;gradient.color0 = .black;gradient.color1 = .white
            return (gradient.outputImage ?? CIImage(color:.black)).cropped(to:rect)
                .applyingFilter("CIMinimumCompositing",parameters:[kCIInputBackgroundImageKey:mask])
        }
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
