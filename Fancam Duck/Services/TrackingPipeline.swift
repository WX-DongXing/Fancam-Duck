import Foundation
import CoreVideo
import CoreGraphics

struct PosePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Float
}
struct PersonObservation: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let body: NormalizedRect
    let confidence: Float
    var keypoints: [PosePoint] = []
    var embedding: [Float] = []
    var focusX:Double {
        let hips=[11,12].compactMap { keypoints.indices.contains($0) && keypoints[$0].confidence>0.4 && keypoints[$0].x.isFinite ? min(1,max(0,keypoints[$0].x)) : nil }
        return hips.count == 2 ? hips.reduce(0,+)/2 : body.center.x
    }
    var protectionBody: NormalizedRect {
        let visible = keypoints.filter { $0.confidence >= 0.35 && $0.x.isFinite && $0.y.isFinite }
        guard !visible.isEmpty else { return body }
        let left = max(0, min(body.x, visible.map(\.x).min()! - body.width * 0.06))
        let top = max(0, min(body.y, visible.map(\.y).min()! - body.height * 0.04))
        let right = min(1, max(body.x + body.width, visible.map(\.x).max()! + body.width * 0.06))
        let bottom = min(1, max(body.y + body.height, visible.map(\.y).max()! + body.height * 0.04))
        return .init(x: left, y: top, width: right - left, height: bottom - top)
    }
}
struct TargetSample: Codable, Sendable, Equatable {
    let time: Double
    let body: NormalizedRect
    var protection: NormalizedRect?
    var trackID: Int = 0
    var focusX: Double? = nil
    var estimated: Bool? = nil
    var keypoints:[PosePoint]? = nil
}
struct TrackingUpdate: Sendable {
    let sample: TargetSample
    let progress: Double
    var preview: CGImage? = nil
    var message:String? = nil
}
struct TrackingResult: Sendable {
    let samples: [TargetSample]
    let issue: TrackingIssue?
    var reviewTimes:[Double]=[]
}

protocol TargetTracking: Sendable {
    func detections(source: URL, time: Double, region: NormalizedRect?) async throws -> [PersonObservation]
    func analyze(source: URL, project: VideoProject, onUpdate: @escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult
    func discard(projectID: UUID) async
    func cachedPeople(source:URL) async -> [Int:DetectionBatch]
    func restorePeople(_ batches:[Int:DetectionBatch],source:URL) async
    func redactions(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult
    func redactions(source: URL, project: VideoProject, onProgress: @escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult
}

extension TargetTracking {
    func redactions(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult {
        try await redactions(source:source,project:project,onProgress:onProgress)
    }
    func discard(projectID: UUID) async {}
    func cachedPeople(source:URL) async -> [Int:DetectionBatch] {[:]}
    func restorePeople(_ batches:[Int:DetectionBatch],source:URL) async {}
    func redactions(source: URL, project: VideoProject, onProgress: @escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult {
        guard !project.settings.redaction.enabled else { throw RedactionError.incomplete }
        return .init(plan:nil,issue:nil)
    }
}

enum TrackingError: LocalizedError {
    case modelsUnavailable
    case incompatibleModel(String)
    case invalidInput
    case decodeTimedOut
    case noTarget
    case invalidTrajectory
    var errorDescription: String? {
        switch self {
        case .modelsUnavailable: "缺少已转换的 YOLO26s-pose 或 OSNet 模型，请重新构建完整工程。"
        case .incompatibleModel(let detail): "模型输出与当前版本不匹配：\(detail)"
        case .decodeTimedOut: "视频解码等待超时，可重试或重新导入。当前编辑已保留。"
        case .invalidInput: "无法读取用于人物分析的画面。"
        case .noTarget: "请先在视频中选择要跟随的舞者。"
        case .invalidTrajectory: "跟踪轨迹不完整，请完成当前人物纠正后重试。"
        }
    }
}

struct PendingModelPipeline: TargetTracking {
    func detections(source: URL, time: Double, region: NormalizedRect?) async throws -> [PersonObservation] { throw TrackingError.modelsUnavailable }
    func analyze(source: URL, project: VideoProject, onUpdate: @escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult { throw TrackingError.modelsUnavailable }
}

extension NormalizedRect {
    func iou(_ other: Self) -> Double {
        let intersection = cgRect.intersection(other.cgRect)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / max(1e-12, width * height + other.width * other.height - area)
    }
    var corners: [CGPoint] {
        [.init(x: x, y: y), .init(x: x, y: y + height), .init(x: x + width, y: y), .init(x: x + width, y: y + height)]
    }
}
