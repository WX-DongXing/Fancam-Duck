import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import UIKit
import Photos

struct ImportedMovie: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: temporary)
            return Self(url: temporary)
        }
    }
}

enum MediaError: LocalizedError {
    case noVideo, invalidDuration, exportFailed, missingSource, cancelled
    var errorDescription: String? {
        switch self {
        case .noVideo: "所选文件没有可读取的视频轨道。"
        case .invalidDuration: "无法读取有效的视频时长。"
        case .exportFailed: "视频导出失败，请检查可用空间后重试。"
        case .missingSource: "源视频已不可用，请重新导入。"
        case .cancelled: "操作已取消。"
        }
    }
}

protocol PhotoSaving:Sendable {func saveToPhotos(url:URL) async throws}

actor MediaService:PhotoSaving {
    static let shared = MediaService()
    func metadata(url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.noVideo }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaError.invalidDuration }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        let fps = try await track.load(.nominalFrameRate)
        return VideoMetadata(width: oriented.width, height: oriented.height, duration: duration, frameRate: Double(fps))
    }
    func thumbnails(url: URL, duration: Double, count: Int = 8, maximumSize: CGSize = CGSize(width:240,height:150)) async -> [UIImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        var images: [UIImage] = []
        for index in 0..<count {
            if Task.isCancelled { break }
            let time = CMTime(seconds: min(duration - 0.01, duration * Double(index) / Double(max(1, count - 1))), preferredTimescale: 600)
            if let result = try? await generator.image(at: time) { images.append(UIImage(cgImage: result.image)) }
        }
        return images
    }
    func saveToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoSaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

enum PhotoSaveError: LocalizedError {
    case denied
    var errorDescription: String? { "未获得相册保存权限。你仍可以通过分享将视频保存到文件。" }
}
