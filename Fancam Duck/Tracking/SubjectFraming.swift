import Foundation

/// A stable body scale, separate from the changing pose/detection envelope.
enum SubjectFraming {
    static func withCachedPoses(_ samples:[TargetSample],people:[Int:DetectionBatch])->[TargetSample] {
        samples.map {sample in
            guard sample.keypoints == nil,let batch=people[AnalysisSampling.key(sample.time)] else {return sample}
            let matches=batch.primary.filter {$0.body.iou(sample.body)>0.85}
            guard matches.count==1 else {return sample}
            var result=sample;result.keypoints=matches[0].keypoints;result.focusX=matches[0].focusX
            return result
        }
    }
    struct Frame:Sendable {
        let time:Double
        let body:NormalizedRect
        let center:CGPoint
        let height:Double
    }
    static func make(_ samples:[TargetSample],source:CGSize)->[Frame] {
        guard source.width>0,source.height>0 else {return []}
        let sorted=samples.filter {$0.time.isFinite && $0.body.isValid}.sorted {$0.time<$1.time}
        guard !sorted.isEmpty else {return []}
        let heights=sorted.filter {$0.estimated != true}.map(\.body.height).sorted()
        let baseline=heights.isEmpty ? sorted[0].body.height : heights[Int(Double(heights.count-1)*0.8)]
        func pose(_ s:TargetSample)->(hip:CGPoint,torso:Double)? {
            guard s.estimated != true,let p=s.keypoints,p.count>=13,
                  [5,6,11,12].allSatisfy({p[$0].confidence>=0.6 && (0...1).contains(p[$0].x) && (0...1).contains(p[$0].y)}) else {return nil}
            let hip=CGPoint(x:(p[11].x+p[12].x)/2,y:(p[11].y+p[12].y)/2)
            let shoulder=CGPoint(x:(p[5].x+p[6].x)/2,y:(p[5].y+p[6].y)/2)
            let torso=hypot((hip.x-shoulder.x)*source.width/source.height,hip.y-shoulder.y)
            guard torso>0.015 else {return nil}
            return (hip,torso)
        }
        let reference=sorted.filter {pose($0) != nil}.min {abs($0.body.height-baseline)<abs($1.body.height-baseline)}
        let referencePose=reference.flatMap(pose)
        let offset=reference.flatMap {s in pose(s).map {(s.body.center.y-$0.hip.y)/s.body.height}} ?? 0
        var scale=1.0
        return sorted.enumerated().map {i,s in
            let current=pose(s)
            if let base=referencePose,let current {
                // A local median rejects an isolated pose/occlusion spike before zooming.
                let nearby=sorted[max(0,i-2)...min(sorted.count-1,i+2)].compactMap {pose($0)?.torso}.sorted()
                let desired=min(3,max(0.25,nearby[nearby.count/2]/base.torso))
                let dt=i>0 ? max(0,s.time-sorted[i-1].time) : 0
                let step=0.18*dt
                scale=i==0 ? desired : min(scale+step,max(scale-step,desired))
                let h=baseline*scale
                return Frame(time:s.time,body:s.body,center:.init(x:current.hip.x,y:current.hip.y+offset*h),height:h)
            }
            // Old/manual samples have no reliable pose: retain scale, never zoom to a crouched box.
            return Frame(time:s.time,body:s.body,center:.init(x:s.focusX ?? s.body.center.x,y:s.body.center.y),height:baseline*scale)
        }
    }
    static func frame(at time:Double,in frames:[Frame])->Frame? {
        guard let first=frames.first,let last=frames.last else {return nil}
        if time<=first.time {return first};if time>=last.time {return last}
        var lo=0,hi=frames.count-1
        while hi-lo>1 {let m=(lo+hi)/2;if frames[m].time<=time {lo=m} else {hi=m}}
        let a=frames[lo],b=frames[hi],u=(time-a.time)/max(0.000001,b.time-a.time)
        func mix(_ x:Double,_ y:Double)->Double {x+(y-x)*u}
        return .init(time:time,body:.init(x:mix(a.body.x,b.body.x),y:mix(a.body.y,b.body.y),width:mix(a.body.width,b.body.width),height:mix(a.body.height,b.body.height)),center:.init(x:mix(a.center.x,b.center.x),y:mix(a.center.y,b.center.y)),height:mix(a.height,b.height))
    }
    static func crop(_ frame:Frame,source:CGSize,aspect:OutputAspectRatio,target:SubjectComposition)->CGRect {
        let maximum=min(source.height,source.width/aspect.value)
        let h=min(maximum,max(min(120,maximum),frame.height*source.height/target.height)),w=h*aspect.value
        return .init(x:min(source.width-w,max(0,frame.center.x*source.width-(0.5+target.x)*w)),y:min(source.height-h,max(0,frame.center.y*source.height-(0.5+target.y)*h)),width:w,height:h)
    }
}
