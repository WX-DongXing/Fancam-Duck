import Foundation

/// Every detected bystander shares the existing pose batches and one TrackTrack instance.
/// The trusted camera trajectory identifies the primary on every frame, including after crossings.
enum AutomaticRedaction {
    static func candidates(_ people:[PersonObservation],primary:NormalizedRect) -> [PersonObservation] {
        let match=people.max {$0.body.iou(primary)<$1.body.iou(primary)}
        let primaryID=match.flatMap {$0.body.iou(primary)>0.2 ? $0.id : nil}
        return people.filter {$0.confidence>=0.3 && $0.id != primaryID && $0.body.iou(primary)<0.6}
    }
    static func region(_ person:PersonObservation,options:RedactionSettings,source:CGSize) -> NormalizedRect {
        if let region=RedactionMotion.region(of:person,settings:options,source:source) {return region}
        // A turned/occluded face must not silently remove protection. Use a conservative upper-body
        // envelope until pose landmarks recover, without a second face detection network.
        return RedactionMotion.clamped(CGRect(x:person.body.x,y:person.body.y-person.body.height*0.03,
                                             width:person.body.width,height:person.body.height*0.35))
    }
    static func build(frames:[(Double,DetectionBatch)],project:VideoProject,samples:[TargetSample]) throws -> RedactionPlan {
        guard !samples.isEmpty,let primary=project.target else {throw RedactionError.incomplete}
        var tracker=TrackTrackTracker()
        tracker.highConfidence=0.3;tracker.initializationConfidence=0.3;tracker.maxLostSteps=6
        var records:[Int:(id:UUID,frames:[RedactionFrame],bodies:[RedactionFrame])]=[:]
        var lastSeen:[Int:(time:Double,body:NormalizedRect,region:NormalizedRect)]=[:]
        let primaryFrames=samples.map {RedactionFrame(time:$0.time,rect:$0.body)}
        for (time,batch) in frames {
            try Task.checkCancellation()
            guard let first=samples.first,let last=samples.last,time>=first.time-0.041,time<=last.time+0.041,
                  let primary=RedactionPlan.rectangle(at:time,frames:primaryFrames) else {throw RedactionError.incomplete}
            let others=candidates(batch.primary,primary:primary)
            let filtered=DetectionBatch(primary:others,relaxed:[])
            _=tracker.update(filtered,time:time)
            for track in tracker.tracks {
                let body:NormalizedRect,mask:NormalizedRect
                if track.missed == 0 {
                    body=track.observation.body
                    mask=region(track.observation,options:project.settings.redaction,source:project.metadata.size)
                    lastSeen[track.id]=(time,body,mask)
                } else {
                    guard let prior=lastSeen[track.id],time-prior.time<=0.6 else {continue}
                    // An absent bystander may be predicted entirely outside the image.
                    // End its visible segment rather than rejecting the whole clip.
                    guard !track.filter.box.cgRect.intersection(CGRect(x:0,y:0,width:1,height:1)).isEmpty else {continue}
                    body=RedactionMotion.clamped(track.filter.box.cgRect)
                    // Don't let an old bystander prediction attach itself to the primary.
                    guard body.iou(primary)<0.35 else {continue}
                    let sx=body.width/max(0.001,prior.body.width),sy=body.height/max(0.001,prior.body.height)
                    mask=RedactionMotion.clamped(CGRect(x:body.x+(prior.region.x-prior.body.x)*sx,y:body.y+(prior.region.y-prior.body.y)*sy,
                                                       width:prior.region.width*sx,height:prior.region.height*sy))
                }
                guard body.isValid,mask.isValid else {throw RedactionError.incomplete}
                if records[track.id] == nil {records[track.id]=(UUID(),[],[])}
                records[track.id]?.frames.append(.init(time:time,rect:mask))
                records[track.id]?.bodies.append(.init(time:time,rect:body))
            }
        }
        // Split interrupted lifetimes; never extrapolate an absent person across the entire clip.
        var tracks:[RedactionTrack]=[]
        for record in records.values {
            var segment:[RedactionFrame]=[],bodies:[RedactionFrame]=[]
            func flush() {
                guard !segment.isEmpty else {return}
                // Cover the interval before a new detection as well, so a face cannot appear
                // uncovered between the 10 Hz detection grid and the output frame grid.
                if let first=segment.first,first.time>project.settings.start+0.001 {
                    segment.insert(.init(time:max(project.settings.start,first.time-0.1),rect:first.rect),at:0)
                    if let body=bodies.first {bodies.insert(.init(time:segment[0].time,rect:body.rect),at:0)}
                }
                tracks.append(.init(subjectID:UUID(),frames:RedactionMotion.smooth(segment),bodies:bodies))
                segment=[];bodies=[]
            }
            for (frame,body) in zip(record.frames,record.bodies) {
                if let last=segment.last,frame.time-last.time>0.151 {flush()}
                segment.append(frame);bodies.append(body)
            }
            flush()
        }
        return .init(subjects:[],region:project.settings.redaction.region,start:project.settings.start,end:project.settings.end,
                     tracks:tracks,automaticTimes:frames.map(\.0),automaticPrimary:.init(time:project.targetTime,body:primary))
    }
}
