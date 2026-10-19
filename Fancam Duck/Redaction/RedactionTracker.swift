import Foundation

/// Identity recovery shares the same conservative gate as camera tracking. Speculative masks
/// are never exported unless that subject is subsequently recovered within the bounded gap.
enum RedactionTracker {
    struct Result { var frames:[RedactionFrame];var issue:RedactionIssue?;var bodies:[RedactionFrame] = [] }
    static func trace(seed:DetectionBatch,anchor:RedactionAnchor,frames:[(Double,DetectionBatch)],
                      options:RedactionSettings,source:CGSize,subjectID:UUID) throws -> Result {
        func issue(_ time:Double) -> Result {
            .init(frames:[],issue:.init(subjectID:subjectID,time:time,message:"打码人物暂时无法确认，请重新轻点同一人物"))
        }
        guard let chosen=seed.primary.max(by:{$0.body.iou(anchor.body)<$1.body.iou(anchor.body)}),chosen.body.iou(anchor.body)>0.2,
              let initial=RedactionMotion.region(of:chosen,settings:options,source:source) else {return issue(anchor.time)}
        var tracker=TrackTrackTracker()
        guard let id=tracker.seed(seed.primary,selectedID:chosen.id,time:anchor.time) else {return issue(anchor.time)}
        var trusted=TargetSample(time:anchor.time,body:chosen.body,protection:chosen.protectionBody,trackID:id,focusX:chosen.focusX)
        var bridge=OcclusionBridge(),output:[RedactionFrame]=[],bodies:[RedactionFrame]=[]
        var head=initial,headBody=chosen.body,lastHeadTime=anchor.time
        for (time,batch) in frames {
            try Task.checkCancellation()
            let observed:PersonObservation?
            let body:NormalizedRect
            if abs(time-anchor.time)<0.001 {observed=chosen;body=chosen.body}
            else {
                var proposed=tracker
                let matches=proposed.update(batch,time:time),candidate=matches[id]
                let ambiguous=candidate.map { person in PersonIdentityGate.isAmbiguous(target:person,others:batch.primary.filter {$0.id != person.id},previousFocus:trusted.focusX ?? trusted.body.center.x,gallery:[chosen.embedding])} ?? false
                let reliable=candidate.map {$0.confidence>=0.35 && Appearance.distance(chosen.embedding,$0.embedding)<0.45 && !ambiguous} ?? false
                if !reliable && !bridge.isActive {bridge.protectedTrackIDs=Set(tracker.tracks.filter {$0.id != id}.map(\.id))}
                let owned=matches.filter {bridge.protectedTrackIDs.contains($0.key)}.map(\.value)
                let unavailable=Set(batch.primary.filter {d in owned.contains {$0.id==d.id || PersonIdentityGate.samePose($0,d)}}.map(\.id))
                let prediction=tracker.coastingTarget(id:id,time:time)
                let predicted=RedactionMotion.clamped(prediction?.filter.box.cgRect ?? trusted.body.cgRect)
                let protectedIDs=bridge.protectedTrackIDs
                let decision=bridge.step(time:time,reference:trusted,predicted:predicted,candidate:candidate,directReliable:reliable,
                    observations:batch.primary,gallery:[chosen.embedding],unavailableIDs:unavailable,trackID:id)
                switch decision {
                case .blocked(let t):return issue(t)
                case .predicted(let sample):
                    if let prediction {proposed.keepCoasting(prediction)}
                    observed=nil;body=sample.protection ?? sample.body
                case .observed(let person,let recovered):
                    // Reconcile the provisional masks with the recovered body path. Keep their
                    // previous coverage as well, so look-ahead recovery cannot reveal a gap.
                    for sample in recovered {
                        let region:NormalizedRect
                        if options.region == .person {
                            let recoveredBody=sample.protection ?? sample.body
                            region=RedactionMotion.clamped(recoveredBody.cgRect.insetBy(dx:-recoveredBody.width*0.12,dy:-recoveredBody.height*0.06))
                        } else {
                            let sx=sample.body.width/max(0.001,headBody.width),sy=sample.body.height/max(0.001,headBody.height)
                            region=RedactionMotion.clamped(CGRect(x:sample.body.x+(head.x-headBody.x)*sx,y:sample.body.y+(head.y-headBody.y)*sy,width:head.width*sx,height:head.height*sy))
                        }
                        if let index=output.firstIndex(where:{abs($0.time-sample.time)<0.001}),region.isValid {
                            output[index].rect=RedactionMotion.clamped(output[index].rect.cgRect.union(region.cgRect))
                        }
                        if let index=bodies.firstIndex(where:{abs($0.time-sample.time)<0.001}) {bodies[index].rect=sample.body}
                    }
                    if let prediction,!protectedIDs.isEmpty {proposed.recover(id:id,observation:person,prediction:prediction,protectedIDs:protectedIDs)}
                    observed=person;body=person.body
                    trusted = .init(time:time,body:person.body,protection:person.protectionBody,trackID:id,focusX:person.focusX)
                }
                tracker=proposed
            }
            let rect:NormalizedRect
            if let observed,let region=RedactionMotion.region(of:observed,settings:options,source:source) {
                rect=region;head=region;headBody=observed.body;lastHeadTime=time
            } else if options.region == .person {
                rect=RedactionMotion.clamped(body.cgRect.insetBy(dx:-body.width*0.12,dy:-body.height*0.06))
            } else {
                guard abs(time-lastHeadTime)<=0.6 else {return issue(time)}
                let sx=body.width/max(0.001,headBody.width),sy=body.height/max(0.001,headBody.height)
                let predicted=CGRect(x:body.x+(head.x-headBody.x)*sx,y:body.y+(head.y-headBody.y)*sy,width:head.width*sx,height:head.height*sy)
                rect=RedactionMotion.clamped(predicted.insetBy(dx:-predicted.width*0.12,dy:-predicted.height*0.12))
            }
            guard rect.isValid else {return issue(time)}
            output.append(.init(time:time,rect:rect))
            bodies.append(.init(time:time,rect:body))
        }
        if let pending=bridge.pending.first {return issue(pending.time)}
        return .init(frames:output,issue:nil,bodies:bodies)
    }
}
