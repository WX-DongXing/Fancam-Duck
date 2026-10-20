import XCTest
import AVFoundation
import CoreVideo
@testable import FancamDuck

final class MediaIntegrationTests: XCTestCase {
    func testRealVideoImportAndPortraitExport() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let metadata = try await MediaService.shared.metadata(url: source)
        XCTAssertEqual(metadata.width, 192, accuracy: 0.01)
        XCTAssertEqual(metadata.height, 108, accuracy: 0.01)
        var project = VideoProject(title: "Fixture", metadata: metadata, settings: EditSettings())
        project.settings.start = 0.1
        project.settings.end = 0.9
        project.settings.resolution = .init(width: 54, height: 96)
        project.target = .init(x: 0.25, y: 0.1, width: 0.3, height: 0.8)
        let output = try await VideoExporter().exportFixedCrop(source: source, project: project)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await MediaService.shared.metadata(url: output)
        XCTAssertEqual(result.width, 54)
        XCTAssertEqual(result.height, 96)
        XCTAssertEqual(result.duration, 0.8, accuracy: 1.0 / 30)
        let thumbnails = await MediaService.shared.thumbnails(url: output, duration: result.duration, count: 2)
        XCTAssertEqual(thumbnails.count, 2)
    }

    func testRotationMetadataUsesUprightDimensions() async throws {
        let source = try await makeVideo(rotated: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let metadata = try await MediaService.shared.metadata(url: source)
        XCTAssertEqual(metadata.width, 108, accuracy: 0.01)
        XCTAssertEqual(metadata.height, 192, accuracy: 0.01)
    }

    func testDeferredRecoveryDeliversMovingVideoFramesAfterManualConfirmation() async throws {
        let source=try await makeVideo(animated:true)
        defer {try? FileManager.default.removeItem(at:source)}
        let pipeline=CoreMLTrackingPipeline()
        var project=VideoProject(title:"Synthetic missing person",metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        project.settings.end=0.8
        project.target = .init(x:0.25,y:0.15,width:0.3,height:0.7)
        let first=try await pipeline.analyze(source:source,project:project) {_ in}
        let issue=try XCTUnwrap(first.issue)
        XCTAssertTrue(issue.requiresManualSelection)
        project.targetTime=issue.time
        let frames=RecoveryPreviewFrames()
        let resumed=try await pipeline.analyze(source:source,project:project) {await frames.record($0)}
        let previews=await frames.previews
        XCTAssertGreaterThan(previews.count,1,"Manual recovery must update the video, not only the target rectangle")
        XCTAssertGreaterThan(Set(previews.map(\.1)).count,1,"The synthetic video changes color over time")
        XCTAssertEqual(previews.map(\.0),previews.map(\.0).sorted())
        XCTAssertTrue(previews.allSatisfy {$0.0>issue.time})
        XCTAssertNotNil(resumed.issue,"A video without people must still block; display references cannot become confirmed tracks")
    }

    private func makeVideo(rotated: Bool = false, animated:Bool=false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 192, AVVideoHeightKey: 108])
        input.expectsMediaDataInRealTime = false
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 108, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 192, kCVPixelBufferHeightKey as String: 108])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? MediaError.exportFailed }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 192, 108, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard result == kCVReturnSuccess, let buffer = pixelBuffer else { throw MediaError.exportFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<108 { for x in 0..<192 {
                let p = base.advanced(by: y * stride + x * 4)
                p[0] = animated ? UInt8(20+index*6) : 50; p[1] = 150; p[2] = 30; p[3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaError.exportFailed }
        return url
    }
}

@MainActor final class ProcessingStateTests: XCTestCase {
    func testDemoBlocksAndRequiresSelectionBeforeResuming() async throws {
        let model = AppModel()
        model.startDemo()
        model.selectTarget(.init(x: 0.3, y: 0.2, width: 0.2, height: 0.7))
        model.confirmProcessing()
        for _ in 0..<100 {
            if model.phase.issue != nil { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        guard let issue = model.phase.issue else { return XCTFail("Expected blocking issue") }
        XCTAssertFalse(model.canConfirm)
        let checkpoint = model.phase.progress
        model.resume()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.phase.progress, checkpoint)
        XCTAssertEqual(model.route, .editor)
        model.selectTarget(.init(x: 0.32, y: 0.2, width: 0.2, height: 0.7))
        XCTAssertTrue(model.canConfirm)
        model.confirmProcessing()
        for _ in 0..<100 {
            if model.route == .export { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertGreaterThan(issue.checkpoint, 0.55)
        XCTAssertEqual(model.route, .export)
        XCTAssertEqual(model.phase, .readyToExport)
    }
}

final class AudioSyncTests: XCTestCase {
    func testOriginalAudioIsRetainedWithTrimmedVideo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("video.mov")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 192, AVVideoHeightKey: 108])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaError.exportFailed }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(nil, 192, 108, kCVPixelFormatType_32BGRA, nil, &pixel)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 96, CVPixelBufferGetBytesPerRow(buffer) * 108)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaError.exportFailed }
        let sound = dir.appendingPathComponent("tone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        var audioFile: AVAudioFile? = try AVAudioFile(forWriting: sound, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 1])
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        pcm.frameLength = 44100
        for i in 0..<44100 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.25) }
        try audioFile?.write(from: pcm)
        audioFile = nil // Finalize the encoded audio before AVFoundation reads it.
        let combined = AVMutableComposition()
        let videoAsset = AVURLAsset(url: movie)
        let audioAsset = AVURLAsset(url: sound)
        defer { withExtendedLifetime(videoAsset) {}; withExtendedLifetime(audioAsset) {} }
        let video = try await videoAsset.loadTracks(withMediaType: .video).first!
        let audio = try await audioAsset.loadTracks(withMediaType: .audio).first!
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        try combined.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: video, at: .zero)
        try combined.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: audio, at: .zero)
        let source = dir.appendingPathComponent("source.mov")
        let mux = try XCTUnwrap(AVAssetExportSession(asset: combined, presetName: AVAssetExportPresetHighestQuality))
        try await mux.export(to: source, as: .mov)
        var project = VideoProject(title: "Audio fixture", metadata: try await MediaService.shared.metadata(url: source), settings: EditSettings())
        project.settings.start = 0.1
        project.settings.end = 0.9
        project.settings.resolution = .init(width: 54, height: 96)
        project.target = .init(x: 0.3, y: 0.1, width: 0.2, height: 0.8)
        let result = try await VideoExporter().exportFixedCrop(source: source, project: project)
        defer { try? FileManager.default.removeItem(at: result) }
        let output = AVURLAsset(url: result)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(audioTracks.count, 1)
        let audioRange = try await audioTracks[0].load(.timeRange)
        let videoRange = try await videoTracks[0].load(.timeRange)
        // Compare against the source's actual audio interval, which can be shorter than video
        // after AAC priming/padding. Missing source audio must not be stretched to fill the cut.
        let sourceAsset = AVURLAsset(url: source)
        let sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio).first!
        let sourceAudioRange = try await sourceAudio.load(.timeRange)
        let selectedRange = CMTimeRange(start: CMTime(seconds: 0.1, preferredTimescale: 600), duration: CMTime(seconds: 0.8, preferredTimescale: 600))
        let overlap = CMTimeRangeGetIntersection(sourceAudioRange, otherRange: selectedRange)
        XCTAssertEqual(audioRange.start.seconds, overlap.start.seconds - selectedRange.start.seconds, accuracy: 1024.0 / 44100)
        XCTAssertEqual(audioRange.duration.seconds, overlap.duration.seconds, accuracy: 1024.0 / 44100)
        XCTAssertEqual(videoRange.duration.seconds, 0.8, accuracy: 0.04)
    }
}

private actor RecoveryPreviewFrames {
    var previews:[(Double,Data)]=[]
    func record(_ update:TrackingUpdate) {
        guard update.message?.contains("回补") == true,let image=update.preview,
              let data=image.dataProvider?.data else {return}
        previews.append((update.sample.time,data as Data))
    }
}
