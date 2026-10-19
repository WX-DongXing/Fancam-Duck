import Foundation

/// Missing frames stay outside the committed trajectory until identity is observed again.
struct DeferredTargetRecovery {
    private(set) var times: [Int:Double] = [:]
    var orderedTimes:[Double] {times.values.sorted()}
    var isEmpty:Bool {times.isEmpty}
    mutating func record(_ time:Double) {times[Int((time*10000).rounded())]=time}
    mutating func resolve(_ time:Double) {times[Int((time*10000).rounded())]=nil}

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
    static func candidate(_ observations:[PersonObservation],gallery:[[Float]],reference:TargetSample?=nil,unavailable:[PersonObservation]=[]) -> PersonObservation? {
        let validGallery=gallery.filter {!$0.isEmpty && $0.allSatisfy(\.isFinite)}
        var distinct:[PersonObservation]=[]
        for observation in observations.sorted(by:{$0.confidence>$1.confidence})
            where observation.body.isValid && observation.confidence>=0.35 && !observation.embedding.isEmpty && observation.embedding.allSatisfy(\.isFinite) {
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
                guard dx<=max(0.15,reference.body.width*2),dy<=max(0.15,reference.body.height) else {return nil}
                motion=min(1,hypot(dx,dy))
            } else {motion=0}
            return (observation,appearance*0.8+motion*0.2)
        }.sorted {$0.1<$1.1}
        guard let best=ranked.first,
              (validGallery.map {Appearance.distance($0,best.0.embedding)}.min() ?? 1)<0.30,
              ranked.count==1 || ranked[1].1-best.1>=0.08,
              !PersonIdentityGate.isAmbiguous(target:best.0,others:distinct.filter {$0.id != best.0.id},
                  previousFocus:reference.map {Double($0.body.center.x)} ?? best.0.focusX,gallery:validGallery) else {return nil}
        return best.0
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
