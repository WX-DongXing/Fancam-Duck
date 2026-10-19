import Foundation
import CoreImage
import ImageIO

/// Offline 10 Hz analysis with sequential decode;
/// inference is serialized to keep model buffers and identity state bounded.
actor CoreMLTrackingPipeline: TargetTracking {
    private var models: CoreMLPeopleModels?
    private let reuseBuffers:Bool
    private let previewInterval:Double
    init(reuseBuffers:Bool=true,previewInterval:Double=0.2) {self.reuseBuffers=reuseBuffers;self.previewInterval=previewInterval}
    private var selectionCache: (source: URL, time: Double, observations: [PersonObservation])?
    private struct Leg { var start: Double; var end: Double; var box: NormalizedRect }
    private struct Configuration:Equatable {
        let source:URL
        let start:Double
        let end:Double
        let anchor:Double
        let box:NormalizedRect
        func sameRange(as other:Self) -> Bool { source==other.source && start==other.start && end==other.end }
    }
    private struct Session {
        var configuration:Configuration
        var legs: [Leg]
        var samples: [TargetSample] = []
        var tracker = TrackTrackTracker()
        var targetID = 0
        var identity: [Float] = []
        var gallery: [[Float]] = []
        var cursor: Double = 0
        var seeded = false
        var blocked = false
        var scanned:Double=0
        var deferred=DeferredTargetRecovery()
        var searching=false
        var confirmation=DeferredTargetRecovery.Confirmation()
        var knownIdentities:[[Float]]=[]
        var searchProtectedIDs:Set<Int>=[]
        var unavailableByTime:[Int:Set<Int>]=[:]
        var occlusion=OcclusionBridge()
        var trusted:TargetSample?
        var lastPreviewTime:Double?
        var lastPreviewEstimated=false
    }
    private var sessions: [UUID: Session] = [:]
    private var redactionSource: URL?
    private var redactionBatches: [Int: DetectionBatch] = [:]
    private func remember(_ batch: DetectionBatch, time: Double, source: URL, enabled: Bool) {
        guard enabled else { return }
        if redactionSource != source { redactionSource=source;redactionBatches.removeAll(keepingCapacity:true) }
        redactionBatches[Int((time*10000).rounded())]=batch
    }
    private func engine() throws -> CoreMLPeopleModels {
        if let models { return models }
        let loaded = try CoreMLPeopleModels(reuseBuffers:reuseBuffers); models = loaded; return loaded
    }
    func discard(projectID: UUID) { sessions[projectID] = nil }
    func cachedPeople(source:URL) -> [Int:DetectionBatch] {redactionSource == source ? redactionBatches : [:]}
    func restorePeople(_ batches:[Int:DetectionBatch],source:URL) {
        redactionSource=source;redactionBatches=batches
    }
    func performanceMetrics() -> CoreMLPeopleModels.Metrics? { models?.metrics }
    func detections(source: URL, time: Double, region: NormalizedRect?) async throws -> [PersonObservation] {
        let engine = try engine()
        let found = try engine.detect(await engine.image(source: source, time: time), region: region).primary.filter { $0.confidence >= 0.3 }
        selectionCache = (source, time, found)
        return found
    }
    func analyze(source: URL, project: VideoProject, onUpdate: @escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult {
        guard let box=project.target,box.isValid else { throw TrackingError.noTarget }
        let start=project.settings.start,end=project.settings.end
        guard start.isFinite,end.isFinite,project.targetTime.isFinite,start>=0,end>start,end<=project.metadata.duration+0.001,
              project.targetTime>=start,project.targetTime<=end else { throw TrackingError.invalidInput }
        let anchor=project.targetTime
        let configuration=Configuration(source:source.standardizedFileURL,start:start,end:end,anchor:anchor,box:box)
        let cached=sessions[project.id]
        var state:Session
        if let cached,cached.configuration.sameRange(as:configuration),cached.blocked || cached.configuration==configuration {
            state=cached;state.configuration=configuration
        } else {
            state=Session(configuration:configuration,legs:[Leg(start:anchor,end:end,box:box),Leg(start:anchor,end:start,box:box)])
        }
        let engine=try engine()
        if state.blocked,state.legs.isEmpty {
            // A user-drawn correction is an explicit anchor, not another candidate search.
            let image=try await engine.image(source:source,time:anchor)
            try Task.checkCancellation()
            let embedding=try engine.embedding(image,body:box)
            state.samples.removeAll {abs($0.time-anchor)<0.001}
            state.samples.append(.init(time:anchor,body:box,trackID:state.targetID))
            state.deferred.resolve(anchor);state.knownIdentities.append(embedding)
            state.blocked=false;sessions[project.id]=state
        }
        if state.blocked, let pending = state.legs.first {
            // Cover the uncertain gap as well as the remaining segment if the user seeks to a clearer frame.
            state.legs.removeFirst()
            let oldCursor = state.cursor
            state.legs.insert(Leg(start: anchor, end: pending.end, box: box), at: 0)
            if abs(anchor-oldCursor) > 0.001 { state.legs.insert(Leg(start: anchor, end: oldCursor, box: box), at: 0) }
            state.seeded = false; state.blocked = false; state.occlusion.reset()
        }
        while let leg = state.legs.first {
            try Task.checkCancellation()
            if !state.seeded {
                let seedImage=try await engine.image(source:source,time:leg.start)
                try Task.checkCancellation()
                var batch = try autoreleasepool { try engine.detect(seedImage,features:true) }
                if !batch.primary.contains(where: { $0.body.iou(leg.box) > 0.4 }) {
                    let local = try autoreleasepool { try engine.detect(seedImage,region:leg.box,features:true) }
                    // Local detections get disjoint IDs before joining the full-frame pool.
                    let remapped = local.primary.enumerated().map { index, d in PersonObservation(id: 10000+index, body: d.body, confidence: d.confidence, keypoints: d.keypoints, embedding: d.embedding) }
                    batch = DetectionBatch(primary: batch.primary + remapped, relaxed: batch.relaxed + remapped)
                }
                if let cache = selectionCache, cache.source == source, abs(cache.time-leg.start) < 0.001,
                   var selected = cache.observations.max(by: { $0.body.iou(leg.box) < $1.body.iou(leg.box) }), selected.body.iou(leg.box) > 0.8 {
                    // Preserve the actual detection the user clicked, rather than repeatedly cropping its output box.
                    selected.embedding = try engine.embedding(seedImage, body: selected.body)
                    let stable = PersonObservation(id: 20000, body: selected.body, confidence: selected.confidence, keypoints: selected.keypoints, embedding: selected.embedding)
                    batch.primary.removeAll { $0.body.iou(stable.body) > 0.7 }
                    batch.primary.append(stable)
                }
                remember(batch,time:leg.start,source:source,enabled:true)
                let detected=batch.primary.max(by:{$0.body.iou(leg.box)<$1.body.iou(leg.box)})
                let chosen:PersonObservation
                if let detected,detected.body.iou(leg.box)>0.15 {chosen=detected}
                else {
                    chosen = .init(id:30000,body:leg.box,confidence:1,embedding:try engine.embedding(seedImage,body:leg.box))
                    batch.primary.append(chosen)
                }
                state.knownIdentities.append(chosen.embedding)
                state.searching=false;state.confirmation = .init()
                state.tracker = TrackTrackTracker()
                state.targetID = state.tracker.seed(batch.primary, selectedID: chosen.id, time: leg.start)!
                state.identity = chosen.embedding; state.gallery=[chosen.embedding]
                state.cursor = leg.start; state.seeded = true
                let seed=TargetSample(time:leg.start,body:chosen.body,protection:chosen.protectionBody,trackID:state.targetID,focusX:chosen.focusX)
                state.samples.append(seed);state.deferred.resolve(leg.start);state.trusted=seed;state.occlusion.reset()
            }
            let direction = leg.end >= leg.start ? 1.0 : -1.0
            let forward = direction > 0 && abs(state.cursor-leg.end)>0.001 ? try await AnalysisFrameReader(source:source,start:state.cursor,end:leg.end) : nil
            // Decode a reverse leg continuously from the beginning. Short seeks in
            // this H.264 source can strand VideoToolbox at ~21s. Cache only full-res
            // inference results and compressed display thumbnails, never 4K buffers.
            var reverse:[Int:(DetectionBatch,Data)]=[:]
            defer { forward?.cancel() }
            if direction<0,abs(state.cursor-leg.end)>0.001 {
                var times:[Double]=[],cursor=state.cursor
                while cursor-leg.end>0.001 {cursor=max(leg.end,cursor-0.1);times.append(cursor)}
                let reader=try await AnalysisFrameReader(source:source,start:0,end:state.cursor)
                defer {reader.cancel()}
                let reference=state.trusted!
                for (index,time) in times.reversed().enumerated() {
                    try Task.checkCancellation()
                    let image=try await reader.imageCancellable(at:time)
                    let batch=try autoreleasepool {try engine.detect(image,features:true,relaxedFeatureThreshold:state.tracker.highConfidence)}
                    remember(batch,time:time,source:source,enabled:true)
                    let preview=try compressedPreview(image,engine:engine)
                    reverse[Int((time*10000).rounded())]=(batch,preview)
                    await onUpdate(.init(sample:reference,progress:min(0.999,state.scanned/max(0.1,end-start)*0.9),message:"正在准备反向分析 · \(index+1)/\(times.count)"))
                }
            }
            while abs(state.cursor-leg.end) > 0.001 {
                try Task.checkCancellation()
                let time = direction > 0 ? min(leg.end, state.cursor+0.1) : max(leg.end, state.cursor-0.1)
                let image:CoreImage.CIImage
                let batch:DetectionBatch
                if let forward {
                    image=try await forward.imageCancellable(at:time)
                    batch=try autoreleasepool {try engine.detect(image,features:true,relaxedFeatureThreshold:state.tracker.highConfidence)}
                } else {
                    guard let cached=reverse.removeValue(forKey:Int((time*10000).rounded())),let preview=CIImage(data:cached.1) else {throw TrackingError.invalidInput}
                    batch=cached.0;image=preview
                }
                try Task.checkCancellation()
                remember(batch,time:time,source:source,enabled:true)
                state.scanned+=abs(time-state.cursor)
                if state.searching {
                    var searchingTracker=state.tracker
                    let searchMatches=searchingTracker.update(batch,time:time)
                    let owned=searchMatches.filter {state.searchProtectedIDs.contains($0.key)}.map(\.value)
                    let unavailable=(batch.primary+batch.relaxed).filter {d in owned.contains {$0.id==d.id || PersonIdentityGate.samePose($0,d)}}
                    state.unavailableByTime[Int((time*10000).rounded())]=Set(unavailable.map(\.id))
                    state.tracker=searchingTracker
                    let match=DeferredTargetRecovery.candidate(batch.primary+batch.relaxed,gallery:state.knownIdentities,unavailable:unavailable)
                    if let found=state.confirmation.accept(match) {
                        state.tracker = TrackTrackTracker()
                        var seedPeople=batch.primary
                        if !seedPeople.contains(where:{$0.id==found.id}) {seedPeople.append(found)}
                        state.targetID=state.tracker.seed(seedPeople,selectedID:found.id,time:time)!
                        state.gallery.append(found.embedding)
                        if state.gallery.count>8 {state.gallery.remove(at:1)}
                        state.occlusion.reset();state.searching=false
                        let sample=TargetSample(time:time,body:found.body,protection:found.protectionBody,trackID:state.targetID,focusX:found.focusX)
                        state.samples.removeAll {abs($0.time-time)<0.001};state.samples.append(sample);state.deferred.resolve(time);state.trusted=sample
                        state.cursor=time;sessions[project.id]=state
                        let preview=renderPreview(image,sample:sample,force:true,state:&state,engine:engine)
                        await onUpdate(.init(sample:sample,progress:min(0.9,state.scanned/max(0.1,end-start)*0.9),preview:preview,message:"已找回主角 · 缺失片段将在扫描后回补"))
                    } else {
                        state.deferred.record(time);state.cursor=time
                        let sample=TargetSample(time:time,body:state.trusted!.body,estimated:true)
                        let preview=renderPreview(image,sample:sample,force:false,state:&state,engine:engine)
                        sessions[project.id]=state
                        await onUpdate(.init(sample:sample,progress:min(0.9,state.scanned/max(0.1,end-start)*0.9),preview:preview,message:"继续扫描 · 缺失片段稍后回补"))
                    }
                    try Task.checkCancellation();continue
                }
                var proposed = state.tracker
                let matches = proposed.update(batch, time: time)
                let matchedCandidate = matches[state.targetID]
                let distance = matchedCandidate.map { c in state.gallery.map { Appearance.distance($0,c.embedding) }.min() ?? 1 } ?? 1
                let previousFocus=state.tracker.tracks.first { $0.id==state.targetID }?.observation.focusX ?? box.center.x
                let ambiguous = matchedCandidate.map { c in
                    PersonIdentityGate.isAmbiguous(target:c,others:batch.primary.filter { $0.id != c.id },previousFocus:previousFocus,gallery:state.gallery)
                } ?? false
                let reference=state.trusted!
                let prediction=state.tracker.coastingTarget(id:state.targetID,time:time)
                let rawPrediction=prediction?.filter.box ?? reference.body
                let predictionWidth=min(1,max(0.001,rawPrediction.width)),predictionHeight=min(1,max(0.001,rawPrediction.height))
                let predicted=ManualBoxGeometry.move(.init(x:rawPrediction.x,y:rawPrediction.y,width:predictionWidth,height:predictionHeight),dx:0,dy:0)
                let directReliable=matchedCandidate.map {$0.confidence>=0.25 && distance<0.5 && !ambiguous} ?? false
                if !directReliable && !state.occlusion.isActive { state.occlusion.protectedTrackIDs=Set(state.tracker.tracks.filter {$0.id != state.targetID}.map(\.id)) }
                let protectedIDs=state.occlusion.protectedTrackIDs
                let owned=matches.filter { protectedIDs.contains($0.key) }.map(\.value)
                let unavailable=Set((batch.primary+batch.relaxed).filter { d in owned.contains {$0.id==d.id || PersonIdentityGate.samePose($0,d)} }.map(\.id))
                if !directReliable || state.occlusion.isActive {state.unavailableByTime[Int((time*10000).rounded())]=unavailable}
                let decision=state.occlusion.step(time:time,reference:reference,predicted:predicted,candidate:matchedCandidate,directReliable:directReliable,observations:batch.primary,gallery:state.gallery,unavailableIDs:unavailable,trackID:state.targetID)
                let accepted:PersonObservation
                switch decision {
                case .predicted(let sample):
                    if let prediction { proposed.keepCoasting(prediction) }
                    state.tracker=proposed;state.cursor=time
                    let preview=renderPreview(image,sample:sample,force:abs(time-leg.end)<0.001,state:&state,engine:engine)
                    sessions[project.id]=state
                    await onUpdate(.init(sample:sample,progress:min(0.999,state.scanned/max(0.1,end-start)*0.9),preview:preview))
                    try Task.checkCancellation()
                    if abs(time-leg.end)>0.001 { continue }
                    for sample in state.occlusion.pending {state.deferred.record(sample.time)}
                    state.searchProtectedIDs=protectedIDs
                    state.occlusion.reset();state.searching=true
                    sessions[project.id]=state
                    continue
                case .blocked(let issueTime):
                    if ambiguous {return block(&state,projectID:project.id,time:issueTime,start:start,end:end)}
                    for sample in state.occlusion.pending {state.deferred.record(sample.time)}
                    state.deferred.record(time);state.searchProtectedIDs=protectedIDs;state.occlusion.reset()
                    state.searching=true;state.confirmation = .init();state.cursor=time
                    let sample=TargetSample(time:time,body:predicted,estimated:true)
                    let preview=renderPreview(image,sample:sample,force:true,state:&state,engine:engine)
                    sessions[project.id]=state
                    await onUpdate(.init(sample:sample,progress:min(0.9,state.scanned/max(0.1,end-start)*0.9),preview:preview,message:"暂未找到主角 · 继续扫描后回补"))
                    try Task.checkCancellation();continue
                case .observed(let found,let bridge):
                    accepted=found
                    if !bridge.isEmpty,let prediction {
                        proposed.recover(id:state.targetID,observation:found,prediction:prediction,protectedIDs:protectedIDs)
                        for sample in bridge {
                            state.samples.removeAll { abs($0.time-sample.time)<0.001 };state.samples.append(sample);state.deferred.resolve(sample.time)
                        }
                    }
                }
                let candidate=accepted
                let acceptedDistance=state.gallery.map { Appearance.distance($0,candidate.embedding) }.min() ?? 1
                // Grow the pose gallery only from high-quality isolated observations still consistent with the original identity.
                let competitors=batch.primary.filter { $0.id != candidate.id && !PersonIdentityGate.samePose(candidate,$0) }
                let isolated = !competitors.contains { $0.body.iou(candidate.body)>0.1 }
                let competitorDistance=competitors.map { d in state.gallery.map { Appearance.distance($0,d.embedding) }.min() ?? 1 }.min() ?? 1
                if candidate.confidence>=0.65 && isolated && Appearance.distance(state.identity,candidate.embedding)<0.45 && competitorDistance-acceptedDistance>0.1 && acceptedDistance>0.06 {
                    state.gallery.append(candidate.embedding)
                    state.knownIdentities.append(candidate.embedding)
                    if state.knownIdentities.count>16 {state.knownIdentities.remove(at:1)}
                    if state.gallery.count>8 { state.gallery.remove(at:1) }
                }
                state.cursor = time; state.tracker = proposed
                let sample = TargetSample(time: time, body: candidate.body, protection: candidate.protectionBody, trackID: state.targetID, focusX: candidate.focusX)
                state.samples.removeAll { abs($0.time-time) < 0.001 }; state.samples.append(sample);state.deferred.resolve(time);state.trusted=sample
                let preview=renderPreview(image,sample:sample,force:abs(time-leg.end)<0.001,state:&state,engine:engine)
                sessions[project.id] = state
                await onUpdate(.init(sample: sample, progress: min(0.999,state.scanned/max(0.1,end-start)*0.9), preview:preview))
                try Task.checkCancellation()
            }
            for sample in state.occlusion.pending {state.deferred.record(sample.time)}
            state.occlusion.reset()
            state.legs.removeFirst(); state.seeded = false; sessions[project.id] = state
        }
        if !state.deferred.isEmpty {
            let anchors=state.samples.filter {$0.estimated != true}.sorted {$0.time<$1.time}
            let pending=state.deferred.orderedTimes
            var reader:AnalysisFrameReader?
            defer {reader?.cancel()}
            for (index,time) in pending.enumerated() {
                try Task.checkCancellation()
                let reference=DeferredTargetRecovery.reference(at:time,anchors:anchors)
                let key=Int((time*10000).rounded())
                var batch=redactionBatches[key] ?? DetectionBatch(primary:[],relaxed:[])
                let excluded=state.unavailableByTime[key] ?? []
                let unavailable=(batch.primary+batch.relaxed).filter {excluded.contains($0.id)}
                var found=DeferredTargetRecovery.candidate(batch.primary+batch.relaxed,gallery:state.knownIdentities,reference:reference,unavailable:unavailable)
                if found == nil,let reference {
                    if reader == nil {reader=try await AnalysisFrameReader(source:source,start:max(0,pending.first!-0.1),end:min(project.metadata.duration,pending.last!+0.001))}
                    let image=try await reader!.imageCancellable(at:time)
                    try Task.checkCancellation()
                    let box=reference.body
                    let left=max(0,box.x-box.width*0.5),top=max(0,box.y-box.height*0.25)
                    let region=NormalizedRect(x:left,y:top,width:min(1,box.x+box.width*1.5)-left,height:min(1,box.y+box.height*1.25)-top)
                    let retry=try engine.detect(image,region:region,features:true)
                    batch=DeferredTargetRecovery.mergingRetry(retry,into:batch)
                    remember(batch,time:time,source:source,enabled:true)
                    found=DeferredTargetRecovery.candidate(batch.primary+batch.relaxed,gallery:state.knownIdentities,reference:reference,unavailable:unavailable)
                }
                if let found {
                    state.samples.removeAll {abs($0.time-time)<0.001}
                    state.samples.append(.init(time:time,body:found.body,protection:found.protectionBody,trackID:state.targetID,focusX:found.focusX))
                    state.deferred.resolve(time)
                }
                sessions[project.id]=state
                if let reference {
                    await onUpdate(.init(sample:reference,progress:0.9+Double(index+1)/Double(pending.count)*0.099,
                        message:"正在回补缺失片段 · \(index+1)/\(pending.count)"))
                }
            }
            if let time=state.deferred.orderedTimes.first {
                state.blocked=true;sessions[project.id]=state
                return .init(samples:state.samples.sorted {$0.time<$1.time},issue:.init(time:time,
                    message:"自动回补后仍无法确认主角，请手动框选人物",checkpoint:0.999,requiresManualSelection:true))
            }
        }
        let sorted = state.samples.sorted { $0.time < $1.time }
        try VideoExporter.validateTrajectory(sorted,project:project)
        try Task.checkCancellation()
        sessions[project.id] = nil
        if let last=sorted.last {await onUpdate(.init(sample:last,progress:1,message:"人物分析完成"))}
        #if DEBUG
        if let data=try? JSONEncoder().encode(sorted) { try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-last-trajectory.json"),options:.atomic) }
        #endif
        return .init(samples: sorted, issue: nil)
    }
    private func compressedPreview(_ image:CIImage,engine:CoreMLPeopleModels) throws -> Data {
        guard let preview=engine.preview(image),let data=CFDataCreateMutable(kCFAllocatorDefault,0),
              let writer=CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil) else {throw TrackingError.invalidInput}
        CGImageDestinationAddImage(writer,preview,[kCGImageDestinationLossyCompressionQuality:0.85] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {throw TrackingError.invalidInput}
        return data as Data
    }
    /// Display sampling is independent of the unchanged 10Hz identity analysis.
    /// A preview and its box are always delivered together; recovery transitions and endpoints are forced.
    private func renderPreview(_ image:CIImage,sample:TargetSample,force:Bool,state:inout Session,engine:CoreMLPeopleModels) -> CGImage? {
        let estimated=sample.estimated == true
        guard force || state.lastPreviewTime == nil || abs(sample.time-state.lastPreviewTime!)>=previewInterval-0.0001 || estimated != state.lastPreviewEstimated else {return nil}
        state.lastPreviewTime=sample.time;state.lastPreviewEstimated=estimated
        return engine.preview(image)
    }
    private func block(_ state:inout Session,projectID:UUID,time:Double,start:Double,end:Double) -> TrackingResult {
        state.blocked=true
        // Discard speculative progress; correction resumes from the last confirmed sample.
        state.cursor=state.trusted?.time ?? state.cursor
        sessions[projectID]=state
        return .init(samples:state.samples.sorted {$0.time<$1.time},issue:.init(time:time,message:"暂时无法可靠找回目标，请在画面中重新点选",checkpoint:min(0.999,state.scanned/max(0.1,end-start)*0.9)))
    }

}

extension CoreMLTrackingPipeline {
    /// All selected subjects consume the same detection/appearance batches. No per-person decode/inference.
    func redactions(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult {
        try await buildRedactions(source:source,project:project,samples:samples,onProgress:onProgress)
    }
    func redactions(source:URL,project:VideoProject,onProgress:@escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult {
        try await buildRedactions(source:source,project:project,samples:[],onProgress:onProgress)
    }
    private func buildRedactions(source: URL, project: VideoProject, samples:[TargetSample], onProgress: @escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult {
        let settings=project.settings,options=settings.redaction
        guard options.enabled else { return .init(plan:nil,issue:nil) }
        if let plan=project.redactionPlan,plan.covers(project) { return .init(plan:plan,issue:nil) }
        guard settings.start.isFinite,settings.end.isFinite,settings.end>settings.start,
              options.subjects.allSatisfy({ !$0.anchors.isEmpty && $0.anchors.allSatisfy { $0.time.isFinite && $0.time>=0 && $0.time<=project.metadata.duration && $0.body.isValid } }) else { throw RedactionError.incomplete }
        if redactionSource != source {redactionSource=source;redactionBatches.removeAll(keepingCapacity:true)}
        let engine=try engine(),before=engine.metrics.poseCalls
        var times:[Double]=[],cursor=settings.start
        while cursor<settings.end-0.001 { times.append(cursor);cursor=min(settings.end,cursor+0.1) }
        times.append(settings.end)
        times += options.subjects.flatMap(\.anchors).map(\.time)
        times=Array(Set(times.map { Int(($0*10000).rounded()) })).sorted().map { Double($0)/10000 }
        let reader=try await AnalysisFrameReader(source:source,start:0,end:max(settings.end,times.last ?? settings.end))
        defer {reader.cancel()}
        let cachedKeys=redactionBatches.keys.sorted()
        var frames:[(Double,DetectionBatch)]=[]
        for (index,time) in times.enumerated() {
            try Task.checkCancellation()
            let exact=Int((time*10000).rounded())
            // Main tracking may use a grid anchored at the selection time. Reuse within half a step;
            // the conservative temporal envelope covers this bounded time offset.
            var low=0,high=cachedKeys.count
            while low<high {let middle=(low+high)/2;if cachedKeys[middle]<exact {low=middle+1} else {high=middle}}
            let near=[low-1,low].filter {cachedKeys.indices.contains($0)}.map {cachedKeys[$0]}.min {abs($0-exact)<abs($1-exact)}
            let batch:DetectionBatch
            if let value=redactionBatches[exact] {batch=value}
            else if let near,abs(near-exact)<=400,let value=redactionBatches[near] {batch=value}
            else {
                let image=try await reader.imageCancellable(at:time)
                batch=try autoreleasepool {try engine.detect(image,features:true)}
                remember(batch,time:time,source:source,enabled:true)
            }
            frames.append((time,batch))
            await onProgress(Double(index+1)/Double(times.count)*0.75)
        }
        if options.allOthers {
            let plan=try AutomaticRedaction.build(frames:frames,project:project,samples:samples)
            guard plan.covers(project) else {throw RedactionError.incomplete}
            await onProgress(1)
            return .init(plan:plan,issue:nil)
        }
        var tracks:[RedactionTrack]=[]
        for (subjectIndex,subject) in options.subjects.enumerated() {
            let anchors=subject.anchors.sorted {$0.time<$1.time}
            var raw:[RedactionFrame]=[],bodies:[RedactionFrame]=[]
            for (index,anchor) in anchors.enumerated() {
                let lower=index==0 ? settings.start : (anchors[index-1].time+anchor.time)/2
                let upper=index==anchors.count-1 ? settings.end : (anchor.time+anchors[index+1].time)/2
                guard let seed=frames.min(by:{abs($0.0-anchor.time)<abs($1.0-anchor.time)}) else {throw RedactionError.incomplete}
                for reverse in [false,true] {
                    let segment=frames.filter { $0.0>=lower-0.001 && $0.0<=upper+0.001 && (reverse ? $0.0<anchor.time-0.001 : $0.0>=anchor.time-0.001) }
                    let result=try RedactionTracker.trace(seed:seed.1,anchor:anchor,frames:reverse ? segment.reversed() : segment,
                                                         options:options,source:project.metadata.size,subjectID:subject.id)
                    if let issue=result.issue {return .init(plan:nil,issue:issue)}
                    raw += result.frames;bodies += result.bodies
                }
            }
            // Exactly one frame per source time, including trim endpoints.
            let unique=Dictionary(raw.map {(Int(($0.time*10000).rounded()),$0)},uniquingKeysWith:{$1})
            let relevant=unique.values.filter {$0.time>=settings.start-0.001 && $0.time<=settings.end+0.001}
            let bodyMap=Dictionary(bodies.map {(Int(($0.time*10000).rounded()),$0)},uniquingKeysWith:{$1})
            tracks.append(.init(subjectID:subject.id,frames:RedactionMotion.smooth(Array(relevant)),bodies:bodyMap.values.sorted {$0.time<$1.time}))
            await onProgress(0.75+0.25*Double(subjectIndex+1)/Double(options.subjects.count))
        }
        let plan=RedactionPlan(subjects:options.subjects,region:options.region,start:settings.start,end:settings.end,tracks:tracks)
        guard plan.covers(project) else {throw RedactionError.incomplete}
        #if DEBUG
        let metrics:[String:Any]=["selectedPeople":options.subjects.count,"sampledFrames":frames.count,"additionalPoseCalls":engine.metrics.poseCalls-before,"cachedBatches":redactionBatches.count]
        if let data=try? JSONSerialization.data(withJSONObject:metrics) {try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-redaction-metrics.json"))}
        #endif
        return .init(plan:plan,issue:nil)
    }
}
