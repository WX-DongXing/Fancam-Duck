import Foundation

/// Bounded offline look-ahead. Predicted samples are provisional until a unique identity
/// is observed in two consecutive frames; unresolved gaps are never silently exported.
struct OcclusionBridge {
    enum Decision { case observed(PersonObservation, [TargetSample]); case predicted(TargetSample); case blocked(Double) }
    var pending:[TargetSample]=[]
    var protectedTrackIDs:Set<Int>=[]
    private var recovery:PersonObservation?
    private var recoveryHits=0
    let maximumGap=1.2
    var isActive:Bool { !pending.isEmpty }

    mutating func step(time:Double,reference:TargetSample,predicted:NormalizedRect,candidate:PersonObservation?,directReliable:Bool,observations:[PersonObservation],gallery:[[Float]],unavailableIDs:Set<Int>,trackID:Int,confirmedIdentity:Bool=false) -> Decision {
        if !isActive && directReliable, let candidate { return .observed(candidate,[]) }
        let elapsed=abs(time-reference.time)
        guard elapsed<=maximumGap+0.001 else { return .blocked(pending.first?.time ?? time) }
        var pool=observations
        if let candidate, !pool.contains(where:{$0.id==candidate.id}) { pool.append(candidate) }
        var distinct:[PersonObservation]=[]
        for d in pool.sorted(by:{$0.confidence>$1.confidence}) where !distinct.contains(where:{PersonIdentityGate.samePose($0,d)}) { distinct.append(d) }
        let radiusX=max(0.06,reference.body.width*(1+elapsed))
        let radiusY=max(0.08,reference.body.height*0.6)
        var ranked=distinct.compactMap { d -> (PersonObservation,Double)? in
            guard d.confidence>=0.35,!unavailableIDs.contains(d.id) else { return nil }
            let appearance=gallery.map { Appearance.distance($0,d.embedding) }.min() ?? 1
            let dx=abs(d.body.center.x-predicted.center.x),dy=abs(d.body.center.y-predicted.center.y)
            guard appearance<0.35,dx<=radiusX,dy<=radiusY else { return nil }
            let motion=hypot(dx/radiusX,dy/radiusY)/sqrt(2)
            return (d,0.7*appearance+0.3*motion)
        }.sorted {$0.1<$1.1}
        // A cached, previously confirmed observation has already passed identity
        // checks. Replaying a manual correction must not classify that boundary again.
        if confirmedIdentity,let candidate {ranked=[(candidate,0)]}
        if let best=ranked.first,ranked.count==1 || ranked[1].1-best.1>=0.08 {
            if let recovery,recovery.body.iou(best.0.body)>0.25,Appearance.distance(recovery.embedding,best.0.embedding)<0.3 { recoveryHits+=1 }
            else { recoveryHits=1 }
            recovery=best.0
            if recoveryHits>=2 {
                let end=TargetSample(time:time,body:best.0.body,protection:best.0.protectionBody,trackID:trackID,focusX:best.0.focusX)
                let bridge=pending.map { sample -> TargetSample in
                    let u=min(1,max(0,abs(sample.time-reference.time)/max(0.001,elapsed)))
                    let t=u*u*(3-2*u)
                    return .init(time:sample.time,body:Self.mix(reference.body,end.body,t),protection:Self.mix(reference.protection ?? reference.body,end.protection ?? end.body,t),trackID:trackID,focusX:(reference.focusX ?? reference.body.center.x)*(1-t)+best.0.focusX*t,estimated:true)
                }
                reset(); return .observed(best.0,bridge)
            }
        } else { recovery=nil;recoveryHits=0 }
        let dx=predicted.center.x-reference.body.center.x,dy=predicted.center.y-reference.body.center.y
        let protection=reference.protection.map { ManualBoxGeometry.move($0,dx:dx,dy:dy) }
        let sample=TargetSample(time:time,body:predicted,protection:protection,trackID:trackID,focusX:min(1,max(0,(reference.focusX ?? reference.body.center.x)+dx)),estimated:true)
        pending.append(sample)
        return .predicted(sample)
    }
    mutating func reset() { pending=[];protectedTrackIDs=[];recovery=nil;recoveryHits=0 }
    private static func mix(_ a:NormalizedRect,_ b:NormalizedRect,_ t:Double) -> NormalizedRect {
        .init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t,width:a.width+(b.width-a.width)*t,height:a.height+(b.height-a.height)*t)
    }
}
