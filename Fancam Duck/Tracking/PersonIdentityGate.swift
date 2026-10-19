import Foundation

/// Limb-expanded boxes may overlap while torsos remain clearly separated.
/// Pause only when a competing appearance is also plausible under the target's recent motion.
enum PersonIdentityGate {
    static func isAmbiguous(target:PersonObservation,others:[PersonObservation],previousFocus:Double,gallery:[[Float]]) -> Bool {
        let targetAppearance=gallery.map { Appearance.distance($0,target.embedding) }.min() ?? 1
        let targetMotion=abs(target.focusX-previousFocus)
        return others.contains { other in
            guard !samePose(target,other) else { return false }
            let appearance=gallery.map { Appearance.distance($0,other.embedding) }.min() ?? 1
            return other.body.iou(target.body)>0.25 && appearance<=targetAppearance+0.025 && abs(other.focusX-previousFocus)<=targetMotion+0.025
        }
    }
    /// TrackTrack may match a relaxed-NMS candidate instead of its high-score duplicate.
    /// Two detections of the same pose must not become two competing identities.
    static func samePose(_ a:PersonObservation,_ b:PersonObservation) -> Bool {
        guard a.body.iou(b.body)>0.4 else { return false }
        let torso=[5,6,11,12].filter { a.keypoints.indices.contains($0) && b.keypoints.indices.contains($0) && a.keypoints[$0].confidence>0.6 && b.keypoints[$0].confidence>0.6 }
        if torso.count>=3 {
            let distance=torso.reduce(0.0) { $0+hypot(a.keypoints[$1].x-b.keypoints[$1].x,a.keypoints[$1].y-b.keypoints[$1].y) }/Double(torso.count)
            if distance/max(0.01,min(a.body.height,b.body.height))<0.02 { return true }
        }
        guard a.body.iou(b.body)>0.8 else { return false }
        let shared=zip(a.keypoints,b.keypoints).filter { $0.confidence>0.4 && $1.confidence>0.4 }
        guard shared.count>=6 else { return false }
        let distance=shared.reduce(0.0) { $0+hypot($1.0.x-$1.1.x,$1.0.y-$1.1.y) }/Double(shared.count)
        return distance/max(0.01,min(a.body.height,b.body.height))<0.035
    }

}
