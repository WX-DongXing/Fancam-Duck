import AVFoundation
import CoreImage

/// Sequential decode with one sampled frame retained; also used to prepare reverse analysis.
/// Video composition applies AVFoundation's upright transform, including rotated input.
final class AnalysisFrameReader {
    private let reader:AVAssetReader
    private let output:AVAssetReaderVideoCompositionOutput
    private var last:CIImage?
    private let readLock = NSLock()
    private var cancelled = false
    private var reading = false

    /// Do not invalidate an output between its cancellation check and the sample read.
    /// Normal task cancellation is deferred until the in-flight sample returns.
    private func nextSample() throws -> CMSampleBuffer? {
        readLock.lock()
        guard !cancelled else { readLock.unlock(); throw CancellationError() }
        reading = true
        readLock.unlock()
        let sample = output.copyNextSampleBuffer()
        readLock.lock()
        reading = false
        let shouldCancel = cancelled
        if shouldCancel { reader.cancelReading() }
        readLock.unlock()
        if shouldCancel { throw CancellationError() }
        return sample
    }
    init(source:URL,start:Double,end:Double) async throws {
        let asset=AVURLAsset(url:source)
        guard let track=try await asset.loadTracks(withMediaType:.video).first else { throw MediaError.noVideo }
        let size=try await track.load(.naturalSize), transform=try await track.load(.preferredTransform)
        let bounds=CGRect(origin:.zero,size:size).applying(transform).standardized
        let duration=try await asset.load(.duration)
        reader=try AVAssetReader(asset:asset)
        output=AVAssetReaderVideoCompositionOutput(videoTracks:[track],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData=false
        let layer=AVMutableVideoCompositionLayerInstruction(assetTrack:track)
        layer.setTransform(transform.concatenating(.init(translationX:-bounds.minX,y:-bounds.minY)),at:.zero)
        let instruction=AVMutableVideoCompositionInstruction();instruction.timeRange=CMTimeRange(start:.zero,duration:duration);instruction.layerInstructions=[layer]
        let composition=AVMutableVideoComposition();composition.renderSize=bounds.size;composition.frameDuration=CMTime(value:1,timescale:30);composition.instructions=[instruction]
        output.videoComposition=composition
        reader.timeRange=CMTimeRange(start:CMTime(seconds:max(0,start),preferredTimescale:600),end:CMTime(seconds:min(duration.seconds,end+0.04),preferredTimescale:600))
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TrackingError.invalidInput }
    }
    func image(at time:Double) throws -> CIImage {
        try Task.checkCancellation()
        let deadline=DecodeReadDeadline(reader:reader)
        let timeout=DispatchWorkItem {deadline.expire()}
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+10,execute:timeout)
        defer {_ = deadline.finish();timeout.cancel()}
        while let sample=try nextSample() {
            try Task.checkCancellation()
            guard let buffer=CMSampleBufferGetImageBuffer(sample) else { continue }
            let image=CIImage(cvPixelBuffer:buffer)
            last=image
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds >= time-0.017 {
                guard !deadline.finish() else {throw TrackingError.decodeTimedOut}
                return image
            }
        }
        try Task.checkCancellation()
        guard !deadline.finish() else {throw TrackingError.decodeTimedOut}
        if reader.status == .failed { throw reader.error ?? TrackingError.invalidInput }
        guard let last else { throw TrackingError.invalidInput };return last
    }
    func imageCancellable(at time:Double) async throws -> CIImage {
        try await withTaskCancellationHandler {
            try image(at:time)
        } onCancel: {self.cancel()}
    }
    func cancel() {
        readLock.lock()
        cancelled = true
        if !reading { reader.cancelReading() }
        readLock.unlock()
    }
    deinit { reader.cancelReading() }
}

/// Cancelling AVAssetReader is independent of the executor blocked in its read.
private final class DecodeReadDeadline:@unchecked Sendable {
    private let lock=NSLock()
    private weak var reader:AVAssetReader?
    private var finished=false
    private var expired=false
    init(reader:AVAssetReader) {self.reader=reader}
    func expire() {
        lock.lock()
        guard !finished else {lock.unlock();return}
        expired=true
        let active=reader
        lock.unlock()
        active?.cancelReading()
    }
    func finish() -> Bool {
        lock.lock();defer {lock.unlock()}
        finished=true
        return expired
    }
}
