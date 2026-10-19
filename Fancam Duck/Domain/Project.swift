import Foundation
import CoreGraphics

struct VideoMetadata: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
    let duration: Double
    let frameRate: Double
    var size: CGSize { CGSize(width: width, height: height) }
}

enum OutputAspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait = "16:9", classic = "4:3", square = "1:1"
    var id: String { rawValue }
    var value: Double {
        switch self { case .portrait: 9.0/16; case .classic: 3.0/4; case .square: 1 }
    }
    // Labels follow the product's height:width convention; geometry uses width/height.
    init(from decoder:Decoder) throws {
        let container=try decoder.singleValueContainer(),label=try container.decode(String.self)
        if label == "9:16" { self = .portrait;return } // Earlier portrait label.
        guard let ratio=Self(rawValue:label) else {
            throw DecodingError.dataCorruptedError(in:container,debugDescription:"Unsupported output aspect")
        }
        self=ratio
    }
    var size: CGSize { .init(width: value, height: 1) }
}

struct OutputResolution: Identifiable, Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }

    static func available(for video: VideoMetadata, aspect: OutputAspectRatio = .portrait) -> [Self] {
        guard video.width >= 2, video.height >= 2 else { return [] }
        let maxHeight = floor(min(video.height, video.width / aspect.value) / 2) * 2
        let maxWidth = Int(floor(maxHeight * aspect.value / 2) * 2)
        guard maxWidth >= 2 else { return [] }
        var sizes = [360, 540, 720, 1080, 1440, 2160].filter { $0 <= maxWidth }.map {
            Self(width: $0, height: Int((Double($0) / aspect.value / 2).rounded()) * 2)
        }.filter { Double($0.height) <= maxHeight }
        if !sizes.contains(where: { $0.width == maxWidth }) {
            sizes.append(Self(width: maxWidth, height: min(Int(maxHeight), Int((Double(maxWidth) / aspect.value / 2).rounded()) * 2)))
        }
        return sizes
    }
}

struct NormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.00001 && y + height <= 1.00001
    }
    static func drawing(from start: CGPoint, to end: CGPoint) -> Self {
        let x1 = min(1, max(0, start.x)), x2 = min(1, max(0, end.x))
        let y1 = min(1, max(0, start.y)), y2 = min(1, max(0, end.y))
        return Self(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }
}

/// The actual source-space viewport chosen by the user, not a ratio of a future automatic crop.
struct CompositionAnchor: Codable, Equatable, Sendable {
    var time: Double
    var crop: NormalizedRect
    var referenceBody: NormalizedRect? = nil
    var isValid: Bool { time.isFinite && crop.isValid }
}

struct EditSettings: Codable, Equatable, Sendable {
    var start: Double = 0
    var end: Double = 0
    var personHeight: Double = 0.75
    var horizontalOffset: Double = 0
    var followSpeed: FollowSpeed = .gentle
    var protectFullBody = true
    var aspectRatio: OutputAspectRatio = .portrait
    var resolution = OutputResolution(width: 1080, height: 1920)
    var compositionAnchor:CompositionAnchor?
    var redaction = RedactionSettings()
    var compositionScale:Double = 1
    var compositionX:Double = 0
    var compositionY:Double = 0
    init() {}
    private enum CodingKeys:String,CodingKey { case redaction,aspectRatio,start,end,personHeight,horizontalOffset,followSpeed,protectFullBody,resolution,compositionScale,compositionX,compositionY,compositionAnchor }
    init(from decoder:Decoder) throws {
        self.init()
        let c=try decoder.container(keyedBy:CodingKeys.self)
        redaction=try c.decodeIfPresent(RedactionSettings.self,forKey:.redaction) ?? .init()
        aspectRatio=try c.decodeIfPresent(OutputAspectRatio.self,forKey:.aspectRatio) ?? .portrait
        start=try c.decodeIfPresent(Double.self,forKey:.start) ?? start
        end=try c.decodeIfPresent(Double.self,forKey:.end) ?? end
        personHeight=try c.decodeIfPresent(Double.self,forKey:.personHeight) ?? personHeight
        horizontalOffset=try c.decodeIfPresent(Double.self,forKey:.horizontalOffset) ?? horizontalOffset
        followSpeed=try c.decodeIfPresent(FollowSpeed.self,forKey:.followSpeed) ?? followSpeed
        protectFullBody=try c.decodeIfPresent(Bool.self,forKey:.protectFullBody) ?? protectFullBody
        resolution=try c.decodeIfPresent(OutputResolution.self,forKey:.resolution) ?? resolution
        compositionAnchor=try c.decodeIfPresent(CompositionAnchor.self,forKey:.compositionAnchor)
        compositionScale=try c.decodeIfPresent(Double.self,forKey:.compositionScale) ?? 1
        compositionX=try c.decodeIfPresent(Double.self,forKey:.compositionX) ?? 0
        compositionY=try c.decodeIfPresent(Double.self,forKey:.compositionY) ?? 0
    }
    enum FollowSpeed: String, Codable, CaseIterable, Sendable {
        case gentle = "舒缓", standard = "标准", responsive = "灵敏"
    }
}

struct VideoProject: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var sourceFileName: String?
    var metadata: VideoMetadata
    var settings: EditSettings
    var target: NormalizedRect?
    var redactionPlan: RedactionPlan?
    var targetTime: Double = 0
    var progressState:String?
    var historyStatus:String {progressState ?? (target == nil ? "待选人" : "待处理")}
    var isDemo = false
    /// Reframe legacy width:first settings when reopened, preserving center and reference time.
    mutating func normalizeOutputAspect() {
        guard metadata.width.isFinite,metadata.height.isFinite,metadata.width>=2,metadata.height>=2 else {return}
        let aspect=settings.aspectRatio
        if abs(Double(settings.resolution.height)-Double(settings.resolution.width)/aspect.value)>2 {
            let sizes=OutputResolution.available(for:metadata,aspect:aspect)
            let budget=max(settings.resolution.width,settings.resolution.height)
            if let size=sizes.last(where:{max($0.width,$0.height)<=budget}) ?? sizes.first {settings.resolution=size}
        }
        if let anchor=settings.compositionAnchor,anchor.isValid,
           abs(anchor.crop.width*metadata.width/(anchor.crop.height*metadata.height)-aspect.value)>0.0001 {
            let original=CGRect(x:anchor.crop.x*metadata.width,y:anchor.crop.y*metadata.height,width:anchor.crop.width*metadata.width,height:anchor.crop.height*metadata.height)
            let crop=CompositionGeometry.reframed(original,source:metadata.size,aspect:aspect)
            settings.compositionAnchor?.crop = .init(x:crop.minX/metadata.width,y:crop.minY/metadata.height,width:crop.width/metadata.width,height:crop.height/metadata.height)
        }
    }
    static var demo: Self {
        let metadata = VideoMetadata(width: 1920, height: 1080, duration: 58.2, frameRate: 30)
        var settings = EditSettings()
        settings.end = metadata.duration
        settings.resolution = OutputResolution.available(for: metadata).last!
        return Self(title: "排练室 · 流程演示", metadata: metadata, settings: settings, isDemo: true)
    }
}

struct TrackingIssue: Equatable, Sendable {
    let time: Double
    let message: String
    let checkpoint: Double
}

enum ProcessingPhase: Equatable {
    case editing
    case processing(progress: Double)
    case paused(progress: Double)
    case blocked(TrackingIssue)
    case readyToExport
    case exporting
    case completed(URL?)

    var canEditTarget: Bool {
        switch self { case .editing, .blocked: true; default: false }
    }
    var progress: Double {
        switch self {
        case .processing(let p), .paused(let p): p
        case .blocked(let issue): issue.checkpoint
        case .readyToExport, .exporting, .completed: 1
        default: 0
        }
    }
    var issue: TrackingIssue? { if case .blocked(let issue) = self { return issue }; return nil }
}

struct ProcessingGate {
    static func canContinue(phase: ProcessingPhase, target: NormalizedRect?, explicitlySelected: Bool) -> Bool {
        guard let target, target.isValid else { return false }
        if case .blocked = phase { return explicitlySelected }
        switch phase { case .editing, .paused: return true; default: return false }
    }
}

struct CropGeometry {
    static func aspectFit(video: CGSize, container: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0 else { return .zero }
        let scale = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
    static func crop(source: CGSize, target: NormalizedRect, personHeight: Double, offset: Double, protect: Bool, aspect: OutputAspectRatio = .portrait) -> CGRect {
        let maxHeight = min(source.height, source.width / aspect.value)
        let desired = source.height * target.height / max(0.1, personHeight)
        let protectedHeight = protect ? max(desired, source.width * target.width / aspect.value) : desired
        let height = min(maxHeight, max(2, protectedHeight))
        let width = height * aspect.value
        let center = target.center
        let x = min(source.width - width, max(0, center.x * source.width - width / 2 + offset * source.width))
        let y = min(source.height - height, max(0, center.y * source.height - height / 2))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension Double {
    var videoTime: String {
        let seconds = isFinite ? max(0, self) : 0
        return String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
