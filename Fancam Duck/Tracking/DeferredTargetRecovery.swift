import Foundation

/// Missing frames stay outside the committed trajectory until identity is observed again.
struct DeferredTargetRecovery {
    private(set) var times: [Int:Double] = [:]
    var orderedTimes:[Double] {times.values.sorted()}
    var isEmpty:Bool {times.isEmpty}
    mutating func record(_ time:Double) {times[Int((time*10000).rounded())]=time}
    mutating func resolve(_ time:Double) {times[Int((time*10000).rounded())]=nil}

    /// Re-track the contiguous missing interval from an explicit human anchor, including
    /// the nearest confirmed frames needed by the bounded occlusion look-ahead.
    func restartRange(around time:Double,manualTime:Double,anchors:[TargetSample])->ClosedRange<Double>? {
        let pending=orderedTimes
        guard let nearest=pending.indices.min(by:{abs(pending[$0]-time)<abs(pending[$1]-time)}) else {return nil}
        var first=nearest,last=nearest
        // The human may confirm a clearer frame after the reported issue. Include
        // every missing frame between them, plus the gap immediately after that anchor.
        while first>0,pending[first-1]>=min(time,manualTime)-0.001 {first-=1}
        while last+1<pending.count,pending[last+1]<=max(time,manualTime)+0.001 {last+=1}
        // One isolated observed frame does not finish OcclusionBridge's two-hit
        // confirmation. Keep both sides of that single frame in the same interval.
        while first>0,min(pending[first],manualTime)-pending[first-1]<=0.251 {first-=1}
        while last+1<pending.count,pending[last+1]-max(pending[last],manualTime)<=0.251 {last+=1}
        let confirmed=anchors.filter {$0.estimated != true}
        // OcclusionBridge requires two consecutive visible observations to confirm recovery.
        let before=confirmed.filter {$0.time<pending[first]-0.001}.map(\.time).sorted()
        let after=confirmed.filter {$0.time>pending[last]+0.001}.map(\.time).sorted()
        let start=before.suffix(2).first ?? pending[first]
        let end=after.prefix(2).last ?? pending[last]
        return min(start,manualTime)...max(end,manualTime)
    }

    /// Local retries can establish new visible boundaries after the original
    /// tracker pass. Reuse the same bounded, two-observation bridge with those
    /// confirmed boundaries before asking the human to confirm another frame.
    func boundedBridges(anchors:[TargetSample],batches:[Int:DetectionBatch]) -> [TargetSample] {
        let confirmed=anchors.filter {$0.estimated != true}.sorted {$0.time<$1.time}
        let pending=orderedTimes
        var result:[TargetSample]=[],index=0
        while index<pending.count {
            let first=index
            while index+1<pending.count,pending[index+1]-pending[index]<=0.251 {index+=1}
            let last=index
            index+=1
            guard let left=confirmed.last(where:{$0.time<pending[first]-0.001}) else {continue}
            let right=Array(confirmed.filter {$0.time>pending[last]+0.001}.prefix(2))
            guard right.count==2,right[1].time-right[0].time<=0.151,
                  right[1].time-left.time<=OcclusionBridge().maximumGap+0.001 else {continue}
            var bridge=OcclusionBridge()
            let times=Array(Set(Array(pending[first...last])+right.map(\.time))).sorted()
            for time in times {
                let sample=right.first {abs($0.time-time)<0.001}
                let known=sample.flatMap {s in
                    let batch=batches[Int((time*10000).rounded())]
                    return ((batch?.primary ?? [])+(batch?.relaxed ?? [])).first {$0.body.iou(s.body)>0.999 && !$0.embedding.isEmpty}
                }
                let decision=bridge.step(time:time,reference:left,predicted:left.body,candidate:known,directReliable:known != nil,
                    observations:known.map {[$0]} ?? [],gallery:[],unavailableIDs:[],trackID:left.trackID ?? 0,confirmedIdentity:known != nil)
                if case .observed(_,let samples)=decision {
                    result+=samples.filter {self.times[Int(($0.time*10000).rounded())] != nil}
                }
            }
        }
        return result
    }

    static func reference(at time:Double,anchors:[TargetSample]) -> TargetSample? {
        guard let first=anchors.first,let last=anchors.last else {return nil}
        if time<=first.time {return .init(time:time,body:first.body,estimated:true)}
        if time>=last.time {return .init(time:time,body:last.body,estimated:true)}
        var lo=0,hi=anchors.count-1
        while hi-lo>1 {let mid=(lo+hi)/2;if anchors[mid].time<time {lo=mid}else{hi=mid}}
        let a=anchors[lo],b=anchors[hi],u=(time-a.time)/max(0.001,b.time-a.time)
        let rect=NormalizedRect(x:a.body.x+(b.body.x-a.body.x)*u,y:a.body.y+(b.body.y-a.body.y)*u,
            width:a.body.width+(b.body.width-a.body.width)*u,height:a.body.height+(b.body.height-a.body.height)*u)
        return .init(time:time,body:rect,estimated:true)
    }
    /// A unique appearance match is required; proximity alone never establishes identity.
    static func candidate(_ observations:[PersonObservation],gallery:[[Float]],reference:TargetSample?=nil,unavailable:[PersonObservation]=[],minimumConfidence:Float=0.35,maximumAppearance:Double=0.30) -> PersonObservation? {
        let validGallery=gallery.filter {!$0.isEmpty && $0.allSatisfy(\.isFinite)}
        var distinct:[PersonObservation]=[]
        for observation in observations.sorted(by:{$0.confidence>$1.confidence})
            where observation.body.isValid && observation.confidence>=minimumConfidence && !observation.embedding.isEmpty && observation.embedding.allSatisfy(\.isFinite) {
            let owned=unavailable.contains {other in
                other.id==observation.id || PersonIdentityGate.samePose(other,observation)
                    || (other.body.iou(observation.body)>0.3 && Appearance.distance(other.embedding,observation.embedding)<0.15)
            }
            if !owned && !distinct.contains(where:{$0.id == observation.id || PersonIdentityGate.samePose($0,observation)}) {distinct.append(observation)}
        }
        let ranked=distinct.compactMap {observation -> (PersonObservation,Double)? in
            let appearance=validGallery.map {Appearance.distance($0,observation.embedding)}.min() ?? 1
            // Keep near-threshold competitors in the ranking; they may invalidate uniqueness.
            guard appearance<0.5 else {return nil}
            let motion:Double
            if let reference {
                let dx=abs(observation.body.center.x-reference.body.center.x)
                let dy=abs(observation.body.center.y-reference.body.center.y)
                let radiusX=max(0.06,reference.body.width*1.5),radiusY=max(0.15,reference.body.height)
                guard dx<=radiusX,dy<=radiusY else {return nil}
                motion=min(1,hypot(dx,dy))
            } else {motion=0}
            return (observation,appearance*0.8+motion*0.2)
        }.sorted {$0.1<$1.1}
        guard let best=ranked.first,
              (validGallery.map {Appearance.distance($0,best.0.embedding)}.min() ?? 1)<maximumAppearance,
              ranked.count==1 || ranked[1].1-best.1>=0.08,
              !PersonIdentityGate.isAmbiguous(target:best.0,others:distinct.filter {$0.id != best.0.id},
                  previousFocus:reference.map {Double($0.body.center.x)} ?? best.0.focusX,gallery:validGallery) else {return nil}
        return best.0
    }
    /// Reuse a verified full-body observation covered by the human's (possibly partial)
    /// box. Otherwise that same person would be seeded again as a protected bystander.
    static func manualSeed(box:NormalizedRect,observations:[PersonObservation],gallery:[[Float]]) -> PersonObservation? {
        let covered=observations.filter {observation in
            let intersection=box.cgRect.intersection(observation.body.cgRect)
            return !intersection.isNull && intersection.width*intersection.height/min(box.width*box.height,observation.body.width*observation.body.height)>=0.6
                && abs(observation.focusX-box.center.x)<=box.width/4+0.005
        }
        if gallery.isEmpty {
            var distinct:[PersonObservation]=[]
            for observation in covered.sorted(by:{$0.confidence>$1.confidence}) where observation.confidence>=0.25 && !observation.embedding.isEmpty {
                if !distinct.contains(where:{PersonIdentityGate.samePose($0,observation)}) {distinct.append(observation)}
            }
            return distinct.count==1 ? distinct[0] : nil
        }
        // The explicit human rectangle supplies location evidence that automatic
        // recovery does not have. A partially visible pose can be below the
        // automatic confidence/appearance limits; uniqueness still applies.
        return candidate(covered,gallery:gallery,reference:.init(time:0,body:box),minimumConfidence:0.25,maximumAppearance:0.5)
    }

    static func duplicatesManualSeed(_ observation:PersonObservation,box:NormalizedRect,embedding:[Float]) -> Bool {
        let intersection=box.cgRect.intersection(observation.body.cgRect)
        let area=min(box.width*box.height,observation.body.width*observation.body.height)
        return !intersection.isNull && intersection.width*intersection.height/area>=0.6
            && abs(observation.focusX-box.center.x)<=box.width/4+0.005
            && Appearance.distance(embedding,observation.embedding)<0.15
    }

    static func seedPeople(_ observations:[PersonObservation],selected:PersonObservation) -> [PersonObservation] {
        observations.filter {other in
            if other.id==selected.id {return true}
            if PersonIdentityGate.samePose(selected,other) {return false}
            // Local and full-frame detections can have different crop extents while
            // sharing the same torso. Do not turn that duplicate into another owner.
            let sameFocus=abs(other.focusX-selected.focusX)<=min(other.body.width,selected.body.width)*0.25+0.005
            return !(sameFocus && duplicatesManualSeed(other,box:selected.body,embedding:selected.embedding))
        }
    }

    static func mergingRetry(_ retry:DetectionBatch,into batch:DetectionBatch) -> DetectionBatch {
        var result=batch
        let base=max(40000,(batch.primary+batch.relaxed).map(\.id).max().map {$0+1} ?? 40000)
        result.primary+=(retry.primary+retry.relaxed).enumerated().map {index,d in
            PersonObservation(id:base+index,body:d.body,confidence:d.confidence,keypoints:d.keypoints,embedding:d.embedding)
        }
        return result
    }
    struct Confirmation {
        private var last:PersonObservation?
        private var hits=0
        mutating func accept(_ candidate:PersonObservation?) -> PersonObservation? {
            guard let candidate else {last=nil;hits=0;return nil}
            if let last,last.body.iou(candidate.body)>0.25,Appearance.distance(last.embedding,candidate.embedding)<0.3 {hits+=1}
            else {hits=1}
            last=candidate
            return hits>=2 ? candidate : nil
        }
    }
}
