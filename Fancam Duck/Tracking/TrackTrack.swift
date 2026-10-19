import Foundation

/// TrackTrack TPA + TAI, adapted to normalized boxes and variable source timestamps.
/// Fixed-camera baseline: CMC is identity. See tools/reference/tracktrack for the pinned MIT reference.
struct TrackTrackTracker {
    struct Track {
        var id: Int
        var filter: BoxKalman
        var observation: PersonObservation
        var feature: [Float]
        var previousScore: Float
        var history: [NormalizedRect]
        var velocity: [CGPoint] = Array(repeating: .zero, count: 4)
        var age = 1
        var missed = 0
        var confirmed: Bool { age >= 2 }
    }
    var tracks: [Track] = []
    var nextID = 1
    var lastTime: Double?
    var matchThreshold = 0.65
    var highConfidence: Float = 0.5
    var initializationConfidence: Float = 0.6
    var maxLostSteps = 15

    mutating func seed(_ observations: [PersonObservation], selectedID: Int, time: Double) -> Int? {
        tracks = []
        lastTime = time
        var target: Int?
        for observation in observations where observation.confidence >= 0.35 || observation.id == selectedID {
            let id = nextID; nextID += 1
            tracks.append(.init(id: id, filter: .init(observation.body), observation: observation, feature: observation.embedding, previousScore: observation.confidence, history: [observation.body], age: 2))
            if observation.id == selectedID { target = id }
        }
        return target
    }
    mutating func update(_ batch: DetectionBatch, time: Double) -> [Int: PersonObservation] {
        let dt = min(5, max(0.05, abs(time - (lastTime ?? time - 0.1)) / 0.1))
        lastTime = time
        for i in tracks.indices { tracks[i].filter.predict(dt: dt, lost: tracks[i].missed > 0) }
        let high = batch.primary.filter { $0.confidence > highConfidence }
        let low = batch.primary.filter { $0.confidence <= highConfidence }
        let suppressed = batch.relaxed.filter { d in d.confidence > highConfidence && !batch.primary.contains { $0.id == d.id } }
        let pool = high + low + suppressed
        let established = tracks.indices.filter { tracks[$0].confirmed }
        var matches = assign(trackIndices: established, detections: pool, highCount: high.count, lowCount: low.count)
        let used = Set(matches.map(\.1))
        let remaining = high.indices.filter { !used.contains($0) }
        let newTracks = tracks.indices.filter { !tracks[$0].confirmed }
        matches += assign(trackIndices: newTracks, detections: remaining.map { high[$0] }, highCount: remaining.count, lowCount: 0).map { ($0.0, remaining[$0.1]) }
        var result: [Int: PersonObservation] = [:]
        let matchedTracks = Set(matches.map(\.0))
        for (i,j) in matches {
            let observation = pool[j]
            let old = tracks[i].observation
            tracks[i].filter.update(observation.body, confidence: Double(observation.confidence))
            let prior = tracks[i].history
            var velocity = Array(repeating: CGPoint.zero, count: 4)
            for delta in 1...3 {
                let box = prior.count >= delta ? prior[prior.count-delta] : prior.last!
                for c in 0..<4 {
                    let p = box.corners[c], q = observation.body.corners[c]
                    let norm = hypot(q.x-p.x,q.y-p.y) + 1e-5
                    velocity[c].x += (q.x-p.x)/norm/Double(delta)/3
                    velocity[c].y += (q.y-p.y)/norm/Double(delta)/3
                }
            }
            tracks[i].velocity = velocity
            tracks[i].previousScore = old.confidence
            tracks[i].observation = observation
            let beta = 0.95 + 0.05 * (1 - Double(observation.confidence))
            tracks[i].feature = Appearance.normalized(zip(tracks[i].feature, observation.embedding).map { Float(beta)*$0.0 + Float(1-beta)*$0.1 })
            tracks[i].history.append(observation.body)
            if tracks[i].history.count > 4 { tracks[i].history.removeFirst() }
            tracks[i].age += 1; tracks[i].missed = 0
            result[tracks[i].id] = observation
        }
        for i in tracks.indices where !matchedTracks.contains(i) { tracks[i].missed += 1 }
        tracks.removeAll { $0.missed > maxLostSteps || (!$0.confirmed && $0.missed > 0) }
        let usedDetections = Set(matches.map(\.1))
        // TAI: suppress candidates already explained by live tracks or a stronger new candidate.
        var accepted: [PersonObservation] = []
        for i in high.indices where !usedDetections.contains(i) && high[i].confidence > initializationConfidence {
            let d = high[i]
            guard !tracks.contains(where: { $0.missed == 0 && $0.filter.box.iou(d.body) > 0.5 }),
                  !accepted.contains(where: { $0.body.iou(d.body) > 0.5 }) else { continue }
            accepted.append(d)
            tracks.append(.init(id: nextID, filter: .init(d.body), observation: d, feature: d.embedding, previousScore: d.confidence, history: [d.body]))
            nextID += 1
        }
        return result
    }
    func assign(trackIndices: [Int], detections: [PersonObservation], highCount: Int, lowCount: Int) -> [(Int,Int)] {
        guard !trackIndices.isEmpty, !detections.isEmpty else { return [] }
        var cost = trackIndices.map { i in detections.enumerated().map { j, d in pairCost(track: tracks[i], detection: d, penalty: j < highCount ? 0 : j < highCount+lowCount ? 0.2 : 0.3) } }
        var threshold = matchThreshold
        var result: [(Int,Int)] = []
        while threshold > 0 {
            let rowMin = cost.map { row in row.indices.min { row[$0] < row[$1] }! }
            let colMin = detections.indices.map { col in cost.indices.min { cost[$0][col] < cost[$1][col] }! }
            let mutual = cost.indices.compactMap { i -> (Int,Int)? in let j = rowMin[i]; return colMin[j] == i && cost[i][j] < threshold ? (i,j) : nil }
            if mutual.isEmpty { break }
            for (i,j) in mutual {
                result.append((trackIndices[i],j))
                for k in detections.indices { cost[i][k] = 1 }
                for k in cost.indices { cost[k][j] = 1 }
            }
            threshold -= 0.05
        }
        return result
    }
    func pairCost(track: Track, detection: PersonObservation, penalty: Double) -> Double {
        let box = track.filter.box, other = detection.body
        let iou = box.iou(other)
        guard iou > 0.1 else { return 1 }
        let hOverlap = (min(box.y+box.height,other.y+other.height) - max(box.y,other.y)) / max(1e-9,max(box.y+box.height,other.y+other.height)-min(box.y,other.y))
        let confidence = abs(Double(track.observation.confidence * 2 - track.previousScore - detection.confidence))
        let old = track.history.count >= 3 ? track.history[track.history.count-3] : track.history.last!
        let angle = zip(zip(old.corners,other.corners),track.velocity).reduce(0.0) { sum, pair in
            let ((p,q),velocity) = pair
            let norm = hypot(q.x-p.x,q.y-p.y) + 1e-5
            let dot = velocity.x*(q.x-p.x)/norm + velocity.y*(q.y-p.y)/norm
            return sum + acos(min(1,max(-1,dot))) / .pi / 4
        } * Double(detection.confidence)
        return min(1,max(0,0.5*(1-hOverlap*iou) + 0.5*Appearance.distance(track.feature,detection.embedding) + 0.1*confidence + 0.05*angle + penalty))
    }
}

/// Four independent position/velocity axes are equivalent to the reference's block-diagonal 8D KF.
struct BoxKalman {
    var position: [Double]
    var velocity = Array(repeating: 0.0, count: 4)
    var p00: [Double]
    var p01 = Array(repeating: 0.0, count: 4)
    var p11: [Double]
    init(_ box: NormalizedRect) {
        position = [box.center.x,box.center.y,box.width,box.height]
        let sizes = [box.width,box.height,box.width,box.height]
        p00 = sizes.map { pow(2*$0,2) }; p11 = sizes.map { pow(10*$0,2) }
    }
    var box: NormalizedRect { .init(x: position[0]-position[2]/2,y: position[1]-position[3]/2,width: max(1e-6,position[2]),height: max(1e-6,position[3])) }
    mutating func predict(dt: Double, lost: Bool) {
        if lost { velocity[2] = 0; velocity[3] = 0 }
        let sizes = [position[2],position[3],position[2],position[3]]
        for i in 0..<4 {
            position[i] += velocity[i]*dt
            p00[i] += 2*dt*p01[i] + dt*dt*p11[i] + pow(sizes[i]/20,2)*dt
            p01[i] += dt*p11[i]
            p11[i] += pow(sizes[i]/160,2)*dt
        }
    }
    mutating func update(_ observation: NormalizedRect, confidence: Double) {
        let measurement = [observation.center.x,observation.center.y,observation.width,observation.height]
        for i in 0..<4 {
            let size = i%2 == 0 ? position[2] : position[3]
            let innovation = p00[i] + pow(size/20,2)*max(0,1-confidence)
            let gain0 = p00[i]/max(1e-12,innovation), gain1 = p01[i]/max(1e-12,innovation)
            let delta = measurement[i]-position[i]
            position[i] += gain0*delta; velocity[i] += gain1*delta
            let old00 = p00[i], old01 = p01[i]
            p00[i] -= gain0*old00; p01[i] -= gain0*old01; p11[i] -= gain1*old01
        }
    }
}

extension TrackTrackTracker {
    func coastingTarget(id:Int,time:Double) -> Track? {
        guard var track=tracks.first(where:{$0.id==id}) else { return nil }
        let dt=min(5,max(0.05,abs(time-(lastTime ?? time-0.1))/0.1))
        track.filter.predict(dt:dt,lost:true)
        // Dampen uncertain velocity rather than running an occluded target across the frame.
        track.filter.velocity[0]*=0.82;track.filter.velocity[1]*=0.82
        track.missed+=1
        return track
    }
    mutating func keepCoasting(_ target:Track) {
        tracks.removeAll {$0.id==target.id};tracks.append(target)
    }
    mutating func recover(id:Int,observation:PersonObservation,prediction:Track,protectedIDs:Set<Int>) {
        var target=prediction
        target.filter.update(observation.body,confidence:Double(observation.confidence))
        target.previousScore=target.observation.confidence;target.observation=observation
        target.feature=Appearance.normalized(zip(target.feature,observation.embedding).map { 0.95*$0.0+0.05*$0.1 })
        target.history.append(observation.body);target.history=Array(target.history.suffix(4))
        target.velocity=Array(repeating:.zero,count:4);target.missed=0;target.age+=1
        tracks.removeAll { $0.id==id || (!protectedIDs.contains($0.id) && PersonIdentityGate.samePose($0.observation,observation)) }
        tracks.append(target)
    }
}
