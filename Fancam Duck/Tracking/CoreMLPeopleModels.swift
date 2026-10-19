import CoreML
import CoreImage
import CoreVideo
import ImageIO
import AVFoundation
import Accelerate

struct DetectionBatch {
    var primary: [PersonObservation]
    var relaxed: [PersonObservation]
}

/// Models and CIContext are confined to the owning tracking actor, never the main thread.
final class CoreMLPeopleModels {
    struct Metrics:Codable {
        var poseCalls=0,reidCalls=0,bufferAllocations=0,poolRequests=0,previewCalls=0
        var detectionSeconds=0.0,poseSeconds=0.0,reidSeconds=0.0,reidInferenceSeconds=0.0,reidReadSeconds=0.0,bufferRenderSeconds=0.0,bufferAcquireSeconds=0.0,previewSeconds=0.0
    }
    private(set) var metrics=Metrics()
    private let pose: MLModel
    private let reid: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace=CGColorSpaceCreateDeviceRGB()
    private let reuseBuffers:Bool
    private var pools:[String:CVPixelBufferPool]=[:]
    init(bundle: Bundle = .main,reuseBuffers:Bool=true) throws {
        self.reuseBuffers=reuseBuffers
        func load(_ name: String) throws -> MLModel {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else { throw TrackingError.modelsUnavailable }
            let config = MLModelConfiguration()
            #if targetEnvironment(simulator)
            config.computeUnits = .cpuOnly
            #else
            config.computeUnits = .all
            #endif
            return try MLModel(contentsOf: url, configuration: config)
        }
        pose = try load("YOLO26sPose")
        reid = try load("OSNetX025")
    }
    func image(source: URL, time: Double) async throws -> CIImage {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: min(max(0, duration - 0.04), max(0, time)), preferredTimescale: 600))
        return CIImage(cgImage: result.image)
    }
    func detect(_ image: CIImage, region: NormalizedRect? = nil, features: Bool = false, relaxedFeatureThreshold:Float = 0.5) throws -> DetectionBatch {
        let detectionStart=CFAbsoluteTimeGetCurrent()
        defer { metrics.detectionSeconds += CFAbsoluteTimeGetCurrent()-detectionStart }
        let full = image.extent
        let requested = region.map { CGRect(x: full.minX + $0.x * full.width, y: full.minY + (1 - $0.y - $0.height) * full.height, width: $0.width * full.width, height: $0.height * full.height).insetBy(dx: -full.width * 0.04, dy: -full.height * 0.04).intersection(full) } ?? full
        guard requested.width > 1, requested.height > 1 else { throw TrackingError.invalidInput }
        let crop = image.cropped(to: requested).transformed(by: .init(translationX: -requested.minX, y: -requested.minY))
        let scale = min(640 / crop.extent.width, 640 / crop.extent.height)
        // Match Ultralytics LetterBox's rounded resize and symmetric 114 padding exactly.
        let resizedWidth = (crop.extent.width * scale).rounded()
        let resizedHeight = (crop.extent.height * scale).rounded()
        let left = ((640 - resizedWidth) / 2 - 0.1).rounded()
        let top = ((640 - resizedHeight) / 2 - 0.1).rounded()
        let bottom = 640 - resizedHeight - top
        let transformed = crop.transformed(by: .init(scaleX: resizedWidth / crop.extent.width, y: resizedHeight / crop.extent.height))
            .transformed(by: .init(translationX: left, y: bottom))
        let background = CIImage(color: CIColor(red: 114/255, green: 114/255, blue: 114/255)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        let buffer = try pixelBuffer(transformed.composited(over: background), width: 640, height: 640)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let poseStart=CFAbsoluteTimeGetCurrent()
        let output = try pose.prediction(from: provider)
        metrics.poseSeconds += CFAbsoluteTimeGetCurrent()-poseStart;metrics.poseCalls+=1
        guard let array = output.featureNames.compactMap({ output.featureValue(for: $0)?.multiArrayValue }).first else { throw TrackingError.incompatibleModel("YOLO tensor missing") }
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] == 56 else { throw TrackingError.incompatibleModel("expected [1,56,N], got \(shape)") }
        func value(_ channel: Int, _ index: Int) -> Float {
            let offset = channel * strides[1] + index * strides[2]
            switch array.dataType {
            case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
            case .float16:
                #if arch(arm64)
                return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
                #else
                return array[offset].floatValue
                #endif
            case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
            default: return array[offset].floatValue
            }
        }
        func point(_ x: Double, _ y: Double) -> (Double, Double) {
            let px = (x - left) / (resizedWidth / requested.width) + requested.minX - full.minX
            let py = (y - top) / (resizedHeight / requested.height) + (full.maxY - requested.maxY)
            return (px / full.width, py / full.height)
        }
        var detections: [PersonObservation] = []
        for index in 0..<shape[2] {
            let confidence = value(4, index)
            guard confidence.isFinite, confidence >= 0.1 else { continue }
            let cx = Double(value(0,index)), cy = Double(value(1,index)), w = Double(value(2,index)), h = Double(value(3,index))
            guard [cx,cy,w,h].allSatisfy(\.isFinite), w > 1, h > 1 else { continue }
            let (x1,y1) = point(cx - w/2, cy - h/2), (x2,y2) = point(cx + w/2, cy + h/2)
            let x = min(1, max(0,x1)), y = min(1,max(0,y1)), right = min(1,max(0,x2)), bottom = min(1,max(0,y2))
            let body = NormalizedRect(x: x, y: y, width: right-x, height: bottom-y)
            guard body.isValid, body.width > 0.005, body.height > 0.01 else { continue }
            let points = (0..<17).map { k -> PosePoint in
                let (px,py) = point(Double(value(5+k*3,index)), Double(value(6+k*3,index)))
                return PosePoint(x: px, y: py, confidence: value(7+k*3,index))
            }
            detections.append(.init(id: index, body: body, confidence: confidence, keypoints: points))
        }
        let candidates = Array(detections.sorted { $0.confidence > $1.confidence }.prefix(300))
        var relaxed = Self.nms(candidates, threshold: 0.95, limit: 60)
        var primary:[PersonObservation]=[]
        for detection in Self.nms(relaxed,threshold:0.7,limit:30) where !primary.contains(where:{PersonIdentityGate.samePose($0,detection)}) { primary.append(detection) }
        if features {
            // TrackTrack uses every primary candidate, but only high-confidence relaxed
            // proposals. Keep those exact crops/features; don't infer identities for unused boxes.
            let needed=Self.featureCandidateIDs(primary:primary,relaxed:relaxed,threshold:relaxedFeatureThreshold)
            for i in relaxed.indices where needed.contains(relaxed[i].id) {
                relaxed[i].embedding = try autoreleasepool { try embedding(image,body:relaxed[i].body) }
            }
            let featuresByID=Dictionary(uniqueKeysWithValues:relaxed.filter {needed.contains($0.id)}.map {($0.id,$0.embedding)})
            for i in primary.indices { primary[i].embedding=featuresByID[primary[i].id] ?? [] }
        }
        return .init(primary: primary, relaxed: relaxed)
    }
    static func featureCandidateIDs(primary:[PersonObservation],relaxed:[PersonObservation],threshold:Float) -> Set<Int> {
        Set(primary.map(\.id)+relaxed.filter {$0.confidence>threshold}.map(\.id))
    }
    func preview(_ image:CIImage) -> CGImage? {
        let began=CFAbsoluteTimeGetCurrent()
        defer {metrics.previewCalls+=1;metrics.previewSeconds+=CFAbsoluteTimeGetCurrent()-began}
        let scale=min(1,960/image.extent.width)
        let reduced=image.transformed(by:.init(scaleX:scale,y:scale))
        return context.createCGImage(reduced,from:reduced.extent)
    }
    func embedding(_ image: CIImage, body: NormalizedRect) throws -> [Float] {
        let reidStart=CFAbsoluteTimeGetCurrent()
        defer { metrics.reidSeconds += CFAbsoluteTimeGetCurrent()-reidStart;metrics.reidCalls+=1 }
        let extent = image.extent
        let bounds = CGRect(x: extent.minX + body.x * extent.width, y: extent.minY + (1-body.y-body.height)*extent.height, width: body.width*extent.width, height: body.height*extent.height).intersection(extent)
        guard bounds.width >= 1, bounds.height >= 1 else { throw TrackingError.invalidInput }
        let crop = image.cropped(to: bounds).transformed(by: .init(translationX: -bounds.minX, y: -bounds.minY))
            .transformed(by: .init(scaleX: 128 / bounds.width, y: 256 / bounds.height))
        let buffer = try pixelBuffer(crop, width: 128, height: 256)
        let inferenceStart=CFAbsoluteTimeGetCurrent()
        let output = try reid.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
        metrics.reidInferenceSeconds += CFAbsoluteTimeGetCurrent()-inferenceStart
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count == 512 else { throw TrackingError.incompatibleModel("OSNet embedding must have 512 values") }
        let readStart=CFAbsoluteTimeGetCurrent()
        let values=(0..<array.count).map {array[$0].floatValue}
        metrics.reidReadSeconds += CFAbsoluteTimeGetCurrent()-readStart
        return Appearance.normalized(values)
    }
    private func pixelBuffer(_ image: CIImage, width: Int, height: Int) throws -> CVPixelBuffer {
        let acquireStart=CFAbsoluteTimeGetCurrent()
        var buffer:CVPixelBuffer?
        let attributes:[String:Any] = [kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        let result:CVReturn
        if reuseBuffers {
            let key="\(width)x\(height)"
            if pools[key] == nil {
                var created:CVPixelBufferPool?
                guard CVPixelBufferPoolCreate(nil,[kCVPixelBufferPoolMinimumBufferCountKey as String:2] as CFDictionary,attributes as CFDictionary,&created)==kCVReturnSuccess,let created else {throw TrackingError.invalidInput}
                pools[key]=created
            }
            result=CVPixelBufferPoolCreatePixelBuffer(nil,pools[key]!,&buffer);metrics.poolRequests+=1
        } else {
            result=CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&buffer);metrics.bufferAllocations+=1
        }
        guard result == kCVReturnSuccess,let buffer else {throw TrackingError.invalidInput}
        metrics.bufferAcquireSeconds+=CFAbsoluteTimeGetCurrent()-acquireStart
        let renderStart=CFAbsoluteTimeGetCurrent()
        context.render(image,to:buffer,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:colorSpace)
        metrics.bufferRenderSeconds+=CFAbsoluteTimeGetCurrent()-renderStart
        return buffer
    }
    static func nms(_ sorted: [PersonObservation], threshold: Double, limit: Int) -> [PersonObservation] {
        var result: [PersonObservation] = []
        for candidate in sorted {
            if !result.contains(where: { $0.body.iou(candidate.body) > threshold }) { result.append(candidate) }
            if result.count >= limit { break }
        }
        return result
    }
}

enum Appearance {
    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + Double($1 * $1) })
        guard norm > 1e-9, norm.isFinite else { return [] }
        return vector.map { Float(Double($0) / norm) }
    }
    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 1 }
        // Vectorized dot product avoids hundreds of boxed/closure operations per association.
        var dot:Float=0
        vDSP_dotpr(a,1,b,1,&dot,vDSP_Length(a.count))
        return min(1,max(0,1-Double(dot)))
    }
}
