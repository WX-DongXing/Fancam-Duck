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

    func testSixHzScanCachesEveryFrameAndReturnsAllMissingTimesWithoutRetry() async throws {
        let source=try await makeVideo(animated:true)
        defer {try? FileManager.default.removeItem(at:source)}
        let pipeline=CoreMLTrackingPipeline()
        var project=VideoProject(title:"Synthetic missing person",metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        project.settings.end=0.8
        project.target = .init(x:0.25,y:0.15,width:0.3,height:0.7)
        let frames=RecoveryPreviewFrames()
        let result=try await pipeline.analyze(source:source,project:project) {await frames.record($0)}
        XCTAssertNotNil(result.issue)
        XCTAssertEqual(result.reviewTimes.count,5)
        XCTAssertEqual(result.reviewTimes.first ?? -1,1.0/6,accuracy:0.001)
        XCTAssertEqual(result.reviewTimes.last ?? -1,0.8,accuracy:0.001)
        let people=await pipeline.cachedPeople(source:source)
        XCTAssertEqual(people.count,6)
        let metrics=await pipeline.performanceMetrics()
        XCTAssertEqual(metrics?.poseCalls,6,"Each sampled frame is inferred once, including an empty detection result")
        XCTAssertEqual(result.samples.count,1,"Missing predictions must not be saved as confirmed identities")
        let previews=await frames.previews
        XCTAssertGreaterThan(previews.count,1)
        XCTAssertGreaterThan(Set(previews.map(\.1)).count,1)
    }

    @MainActor func testRedactedPreviewReusesCameraFramesAndExportsTrimmedSyntheticVideo() async throws {
        let source=try await makeVideo(animated:true)
        defer {try? FileManager.default.removeItem(at:source)}
        let metadata=try await MediaService.shared.metadata(url:source)
        var project=VideoProject(title:"Synthetic camera reuse",metadata:metadata,settings:EditSettings())
        project.settings.start=0.1;project.settings.end=0.9
        project.settings.resolution = .init(width:54,height:96)
        let samples=(0...6).map {TargetSample(time:Double($0)/6,body:.init(x:0.2+Double($0)*0.04,y:0.15,width:0.2,height:0.7))}
        project.target=samples[0].body;project.targetTime=0
        project.settings.redaction = .init(allOthers:true)
        project.redactionPlan = .init(subjects:[],region:.face,start:0,end:1,tracks:[],
            automaticTimes:samples.map(\.time),automaticPrimary:.init(time:0,body:samples[0].body))
        let expected=CropPlan.renderFrames(CropPlan.make(samples:samples,source:metadata.size,settings:project.settings),frameRate:metadata.frameRate)
        let exporter=VideoExporter()
        let preview=try await exporter.preview(source:source,project:project,samples:samples)
        let video=try XCTUnwrap(preview.videoComposition)
        let instruction=try XCTUnwrap(video.instructions.first as? RedactionInstruction)
        XCTAssertEqual(instruction.crops.map(\.time),expected.map(\.time))
        XCTAssertEqual(instruction.crops.map(\.rect),expected.map(\.rect))
        XCTAssertEqual(instruction.sourceStart,0.1,accuracy:0.0001)
        XCTAssertEqual(instruction.timeRange.duration.seconds,0.8,accuracy:0.0001)
        let output=try await exporter.exportMovingCrop(source:source,project:project,samples:samples)
        defer {try? FileManager.default.removeItem(at:output)}
        let result=try await MediaService.shared.metadata(url:output)
        XCTAssertEqual(result.width,54);XCTAssertEqual(result.height,96)
        XCTAssertEqual(result.duration,0.8,accuracy:1/30)
    }

    @MainActor func testPausedRedactionPreviewFollowsCachedPeopleAtTheSelectedTime() async throws {
        let source=try await makeVideo()
        defer {try? FileManager.default.removeItem(at:source)}
        var project=VideoProject(title:"Moving masks",metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        project.settings.end=1
        project.settings.redaction = .init(region:.person,allOthers:true)
        let samples=(0...6).map {index in TargetSample(time:Double(index)/6,body:.init(x:0.1+Double(index)/60,y:0.1,width:0.15,height:0.8))}
        project.target=samples[0].body
        let batches=Dictionary(uniqueKeysWithValues:samples.map {sample in
            (Int((sample.time*10000).rounded()),DetectionBatch(primary:[
                PersonObservation(id:1,body:sample.body,confidence:0.9,embedding:[1,0]),
                PersonObservation(id:2,body:.init(x:0.7-sample.time*0.2,y:0.1,width:0.15,height:0.8),confidence:0.9,embedding:[0,1])],relaxed:[]))
        })
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory)
        try await store.prepare()
        project.sourceFileName=try await store.importFile(source).lastPathComponent
        try await store.save(project)
        try await store.saveTrajectory(project:project,samples:samples,people:batches)
        let model=AppModel(store:store)
        defer {model.goHome()}
        model.open(project)
        for _ in 0..<400 {if !model.restoringTracking {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(model.hasCompletedTracking)
        let item=try XCTUnwrap(model.player?.currentItem)
        model.detectPeople()
        for _ in 0..<400 {if (item.videoComposition?.instructions.first as? RedactionInstruction)?.plan.tracks.isEmpty == false || model.errorMessage != nil {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertNil(model.errorMessage)
        let instruction=try XCTUnwrap(item.videoComposition?.instructions.first as? RedactionInstruction)
        let early=try XCTUnwrap(instruction.plan.rectangles(at:0.1).first)
        model.scrub(to:0.9);model.finishScrubbing()
        let late=try XCTUnwrap(instruction.plan.rectangles(at:0.9).first)
        XCTAssertGreaterThan(early.x-late.x,0.1,"Masks must move with cached bystanders instead of keeping the opening frame")
        XCTAssertLessThan(late.iou(samples.last!.body),0.1,"The moving primary must remain unmasked")
        XCTAssertEqual(model.currentTime,0.9,accuracy:0.001)
        XCTAssertNil(model.project?.redactionPlan,"A settings preview must not mark an unvalidated export plan complete")
        XCTAssertTrue(item.videoComposition?.customVideoCompositorClass == RedactionCompositor.self)
    }

    @MainActor func testSubjectZoomPreviewAndEncodedFramesUseSameSourceTime() async throws {
        let source=try await makeVideo(scale:4,grid:true)
        defer {try? FileManager.default.removeItem(at:source)}
        let metadata=try await MediaService.shared.metadata(url:source)
        var project=VideoProject(title:"Subject crop fixture",metadata:metadata,settings:EditSettings())
        project.settings.start=0.1;project.settings.end=0.9;project.settings.resolution = .init(width:54,height:96)
        let samples=(0...6).map {i -> TargetSample in
            let t=Double(i)/6,scale=1+t*0.2,x=0.42+t*0.12
            var p=Array(repeating:PosePoint(x:x,y:0.5,confidence:0),count:17)
            for j in [5,6] {p[j] = .init(x:x,y:0.5-0.12*scale,confidence:1)}
            for j in [11,12] {p[j] = .init(x:x,y:0.5,confidence:1)}
            return .init(time:t,body:.init(x:x-0.05,y:0.5-0.22*scale,width:0.1,height:0.4*scale),focusX:x,keypoints:p)
        }
        project.target=samples[0].body
        let plan=CropPlan.renderFrames(CropPlan.make(samples:samples,source:metadata.size,settings:project.settings),frameRate:30)
        XCTAssertGreaterThan(plan.last!.rect.height,plan.first!.rect.height*1.1)
        let exporter=VideoExporter(),preview=try await exporter.preview(source:source,project:project,samples:samples)
        let output=try await exporter.exportMovingCrop(source:source,project:project,samples:samples)
        defer {try? FileManager.default.removeItem(at:output)}
        let outputMetadata=try await MediaService.shared.metadata(url:output)
        XCTAssertEqual(outputMetadata.duration,0.8,accuracy:1.0/30)
        let expected=AVAssetImageGenerator(asset:preview.asset);expected.videoComposition=preview.videoComposition
        let actual=AVAssetImageGenerator(asset:AVURLAsset(url:output))
        let original=AVAssetImageGenerator(asset:AVURLAsset(url:source))
        for generator in [expected,actual,original] {generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero}
        let context=CIContext()
        for t in [0.2,0.6] {
            let time=CMTime(seconds:t,preferredTimescale:600)
            let a=try await expected.image(at:time).image,b=try await actual.image(at:time).image
            func pixel(_ image:CGImage,at point:CGPoint = .init(x:27,y:48))->[UInt8] {
                var rgba=[UInt8](repeating:0,count:4)
                context.render(CIImage(cgImage:image),toBitmap:&rgba,rowBytes:4,bounds:CGRect(x:point.x,y:point.y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
                return rgba
            }
            let pa=pixel(a),pb=pixel(b)
            for i in 0..<3 {XCTAssertEqual(Double(pa[i]),Double(pb[i]),accuracy:10)}
            let crop=try XCTUnwrap(CropPlan.rect(at:project.settings.start+t,in:plan))
            let sourceImage=try await original.image(at:CMTime(seconds:project.settings.start+t,preferredTimescale:600)).image
            let sourcePixel=pixel(sourceImage,at:.init(x:crop.midX,y:metadata.height-crop.midY))
            XCTAssertEqual(Double(pb[0]),Double(sourcePixel[0]),accuracy:10)
        }
    }

    private func makeVideo(rotated: Bool = false, animated:Bool=false,scale:Int=1,grid:Bool=false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 192*scale, AVVideoHeightKey: 108*scale])
        input.expectsMediaDataInRealTime = false
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 108, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 192*scale, kCVPixelBufferHeightKey as String: 108*scale])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? MediaError.exportFailed }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 192*scale, 108*scale, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard result == kCVReturnSuccess, let buffer = pixelBuffer else { throw MediaError.exportFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<108*scale { for x in 0..<192*scale {
                let p = base.advanced(by: y * stride + x * 4)
                p[0] = animated ? UInt8(20+index*6) : 50; p[1] = grid ? UInt8(y*255/(108*scale)) : 150; p[2] = grid ? UInt8(x*255/(192*scale)) : 30; p[3] = 255
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
        guard let image=update.preview,
              let data=image.dataProvider?.data else {return}
        previews.append((update.sample.time,data as Data))
    }
}
