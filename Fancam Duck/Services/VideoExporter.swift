import AVFoundation
import Foundation
import CoreImage

/// Preview and export share source-time camera transforms and sample-accurate audio trimming.
protocol VideoExporting:Sendable {
    @MainActor func preview(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> AVPlayerItem
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> URL
}
extension VideoExporting {
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> URL {
        let url=try await exportMovingCrop(source:source,project:project,samples:samples)
        await onProgress(1);return url
    }
}

actor VideoExporter:VideoExporting {
    private var session: AVAssetExportSession?
    func cancel() { session?.cancelExport() }
    func exportFixedCrop(source: URL, project: VideoProject) async throws -> URL {
        try await exportComposition(source: source, project: project, samples: [])
    }
    @MainActor func preview(source: URL, project: VideoProject, samples: [TargetSample]) async throws -> AVPlayerItem {
        try Self.validateTrajectory(samples,project:project)
        let (asset, video, audio) = try await composition(source: source, project: project, samples: samples)
        let item = AVPlayerItem(asset: asset); item.videoComposition = video; item.audioMix = audio
        return item
    }
    private func composition(source: URL, project: VideoProject, samples: [TargetSample]) async throws -> (AVMutableComposition, AVMutableVideoComposition, AVMutableAudioMix?) {
        try Task.checkCancellation()
        guard let target = project.target, target.isValid else { throw MediaError.noVideo }
        if project.settings.redaction.enabled {
            guard RedactionPolicy.conflicts(project:project,samples:samples).isEmpty else {throw RedactionError.primaryTarget}
            guard project.redactionPlan?.covers(project) == true,
                  project.settings.redaction.style != .image || project.settings.redaction.imageData.flatMap({RedactionImage.decode($0)}) != nil else { throw RedactionError.incomplete }
        }
        let output=project.settings.resolution
        guard project.settings.start.isFinite,project.settings.end.isFinite,project.settings.personHeight.isFinite,
              project.settings.compositionScale.isFinite,project.settings.compositionScale>0,
              project.settings.compositionX.isFinite,project.settings.compositionY.isFinite,
              project.settings.personHeight>0,project.settings.horizontalOffset.isFinite,
              output.width>=2,output.height>=2,output.width%2==0,output.height%2==0,
              abs(Double(output.height)-Double(output.width)/project.settings.aspectRatio.value)<=2 else { throw TrackingError.invalidInput }
        if let anchor=project.settings.compositionAnchor {
            guard anchor.isValid,anchor.time>=0,anchor.time<=project.metadata.duration,
                  abs(anchor.crop.width*project.metadata.width/(anchor.crop.height*project.metadata.height)-project.settings.aspectRatio.value)<0.0001 else {throw TrackingError.invalidInput}
        }
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaError.noVideo }
        let duration = try await asset.load(.duration).seconds
        let start=project.settings.start,end=project.settings.end
        guard duration.isFinite,start>=0,end>start,end<=duration+0.001 else { throw MediaError.invalidDuration }
        let interval = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: end - start, preferredTimescale: 600))
        try videoTrack.insertTimeRange(interval, of: video, at: .zero)
        var audioMix: AVMutableAudioMix?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = try await audio.load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(interval, otherRange: audioRange)
            if overlap.duration > .zero {
                try audioTrack.insertTimeRange(overlap, of: audio, at: overlap.start - interval.start)
                // Force sample-accurate audio rendering rather than compressed AAC packet trimming.
                // Packet passthrough can otherwise drop up to two boundary packets on short cuts.
                let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                parameters.setVolume(1, at: .zero)
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                audioMix = mix
            }
        }
        let transform = try await video.load(.preferredTransform)
        let naturalSize = try await video.load(.naturalSize)
        let uprightBounds = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        let crop = CropGeometry.crop(source: uprightBounds.size, target: target, personHeight: project.settings.personHeight, offset: project.settings.horizontalOffset, protect: project.settings.protectFullBody, aspect: project.settings.aspectRatio)
        let scaleX = Double(output.width) / crop.width
        let scaleY = Double(output.height) / crop.height
        let renderTransform = transform
            .concatenating(CGAffineTransform(translationX: -uprightBounds.minX - crop.minX, y: -uprightBounds.minY - crop.minY))
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
        let sourceRate=Double(try await video.load(.nominalFrameRate))
        let rate=sourceRate.isFinite && sourceRate>0 ? min(60,sourceRate) : 30
        // Solve once. The custom compositor consumes these frames directly and does not
        // use AVFoundation layer ramps, so avoid constructing the discarded composition.
        let frames = samples.isEmpty ? [CropPlan.Frame(time:start,rect:crop)] : CropPlan.renderFrames(
            CropPlan.make(samples:samples,source:uprightBounds.size,settings:project.settings),
            frameRate:rate,preserving:project.settings.compositionAnchor?.time)
        try Task.checkCancellation()
        let plan=CropPlan.clipped(frames,start:start,end:end)
        #if DEBUG
        if !samples.isEmpty,let data=try? JSONEncoder().encode(plan) {try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-last-camera.json"),options:.atomic)}
        #endif
        let range=CMTimeRange(start:.zero,duration:interval.duration)
        let renderSize=CGSize(width:output.width,height:output.height)
        if project.settings.redaction.enabled,let redaction=project.redactionPlan {
            let normalized=transform.concatenating(.init(translationX:-uprightBounds.minX,y:-uprightBounds.minY))
            let rendered=RedactionRenderer.composition(trackID:videoTrack.trackID,range:range,transform:normalized,
                source:uprightBounds.size,output:renderSize,start:start,crops:frames,plan:redaction,strength:project.settings.redaction.strength,rate:rate,style:project.settings.redaction.style,imageData:project.settings.redaction.imageData)
            return (composition,rendered,audioMix)
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(renderTransform, at: .zero)
        if !samples.isEmpty {
            func transformFor(_ crop: CGRect) -> CGAffineTransform {
                transform.concatenating(CGAffineTransform(translationX: -uprightBounds.minX-crop.minX, y: -uprightBounds.minY-crop.minY))
                    .concatenating(CGAffineTransform(scaleX: Double(output.width)/crop.width, y: Double(output.height)/crop.height))
            }
            if let first = plan.first { layer.setTransform(transformFor(first.rect), at: .zero) }
            for i in 1..<plan.count {
                let a = plan[i-1], b = plan[i]
                let t = max(0,a.time-start), stop = min(end-start,b.time-start)
                guard stop > t else { continue }
                let beginTime=CMTime(seconds:t,preferredTimescale:60000),stopTime=CMTime(seconds:stop,preferredTimescale:60000)
                guard stopTime>beginTime else { continue }
                layer.setTransformRamp(fromStart:transformFor(a.rect),toEnd:transformFor(b.rect),timeRange:CMTimeRange(start:beginTime,end:stopTime))
            }
        }
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = CGSize(width: output.width, height: output.height)
        videoComposition.frameDuration=CMTime(seconds:1/rate,preferredTimescale:60000)
        return (composition, videoComposition, audioMix)
    }
    nonisolated static func validateTrajectory(_ samples:[TargetSample],project:VideoProject) throws {
        let start=project.settings.start,end=project.settings.end
        guard start.isFinite,end.isFinite,start>=0,end>start,!samples.isEmpty,
              samples.allSatisfy({ sample in
                  sample.time.isFinite && sample.time>=0 && sample.time<=project.metadata.duration+0.001 && sample.body.isValid &&
                  (sample.protection?.isValid ?? true) && (sample.focusX.map {$0.isFinite && $0>=0 && $0<=1} ?? true)
              }) else { throw TrackingError.invalidTrajectory }
        let sorted=samples.sorted {$0.time<$1.time}
        guard sorted.first!.time<=start+0.001,sorted.last!.time>=end-0.001,
              zip(sorted,sorted.dropFirst()).allSatisfy({$1.time-$0.time<=AnalysisSampling.maximumSampleGap}) else { throw TrackingError.invalidTrajectory }
    }
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL {
        try await exportMovingCrop(source:source,project:project,samples:samples,onProgress:{_ in})
    }
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> URL {
        try Self.validateTrajectory(samples,project:project)
        return try await exportComposition(source:source,project:project,samples:samples,onProgress:onProgress)
    }
    private func exportComposition(source: URL, project: VideoProject, samples: [TargetSample],onProgress:@escaping @Sendable (Double) async -> Void={_ in},allowCompatibilityRetry:Bool=true) async throws -> URL {
        let (composition, videoComposition, audioMix) = try await composition(source: source, project: project, samples: samples)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw MediaError.exportFailed }
        session = exporter
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-\(UUID().uuidString).mp4")
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix
        exporter.shouldOptimizeForNetworkUse = true
        let progressTask=Task {
            for await state in exporter.states(updateInterval:0.2) {
                if Task.isCancelled {break}
                if case .exporting(let progress)=state {await onProgress(min(0.99,max(0,progress.fractionCompleted)))}
            }
        }
        defer {progressTask.cancel()}
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to: url, as: .mp4)
            } onCancel: {
                exporter.cancelExport()
            }
            session = nil
            await onProgress(1)
            return url
        } catch {
            session = nil
            try? FileManager.default.removeItem(at: url)
            let failure=error as NSError
            if allowCompatibilityRetry,!Task.isCancelled,failure.domain==AVFoundationErrorDomain,failure.code==AVError.Code.decodeFailed.rawValue {
                let compatible=try await compatibleSource(source,onProgress:{await onProgress($0*0.35)})
                defer {try? FileManager.default.removeItem(at:compatible)}
                return try await exportComposition(source:compatible,project:project,samples:samples,onProgress:{await onProgress(0.35+$0*0.65)},allowCompatibilityRetry:false)
            }
            throw error
        }
    }
    /// Some H.264 inputs decode continuously but fail when a composition starts
    /// inside their GOP. Normalize the whole stream once, without cropping or
    /// changing source coordinates, then retry the exact same camera composition.
    private func compatibleSource(_ source:URL,onProgress:@escaping @Sendable (Double) async -> Void) async throws -> URL {
        guard let exporter=AVAssetExportSession(asset:AVURLAsset(url:source),presetName:AVAssetExportPresetHighestQuality) else {throw MediaError.exportFailed}
        session=exporter
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-compatible-"+UUID().uuidString).appendingPathExtension("mov")
        let progress=Task {
            for await state in exporter.states(updateInterval:0.2) {
                if Task.isCancelled {break}
                if case .exporting(let value)=state {await onProgress(min(0.99,max(0,value.fractionCompleted)))}
            }
        }
        defer {progress.cancel();session=nil}
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to:url,as:.mov)
            } onCancel: {exporter.cancelExport()}
            try Task.checkCancellation()
            await onProgress(1)
            return url
        } catch {
            try? FileManager.default.removeItem(at:url)
            throw error
        }
    }

}
