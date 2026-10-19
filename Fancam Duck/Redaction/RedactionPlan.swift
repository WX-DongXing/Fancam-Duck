import Foundation
import CoreGraphics

struct RedactionAnchor: Codable, Equatable, Sendable {
    var time: Double
    var body: NormalizedRect
}
struct RedactionSubject: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var anchors: [RedactionAnchor]
}
struct RedactionSettings: Codable, Equatable, Sendable {
    enum Region: String, Codable, CaseIterable { case face = "人脸", person = "整个人物" }
    enum Style: String, Codable, CaseIterable { case frosted = "毛玻璃", mosaic = "马赛克", image = "图片" }
    var style: Style = .frosted
    var imageData: Data?
    var subjects: [RedactionSubject] = []
    var region: Region = .face
    var strength: Double = 0.65
    var allOthers = false
    var enabled: Bool { allOthers || !subjects.isEmpty }
    init(subjects:[RedactionSubject]=[],region:Region = .face,strength:Double=0.65,style:Style = .frosted,imageData:Data?=nil,allOthers:Bool=false) {
        self.subjects=subjects;self.region=region;self.strength=strength;self.style=style;self.imageData=imageData;self.allOthers=allOthers
    }
    private enum CodingKeys:String,CodingKey {case subjects,region,strength,style,imageData,allOthers}
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        allOthers=try values.decodeIfPresent(Bool.self,forKey:.allOthers) ?? false
        subjects=try values.decodeIfPresent([RedactionSubject].self,forKey:.subjects) ?? []
        region=try values.decodeIfPresent(Region.self,forKey:.region) ?? .face
        strength=try values.decodeIfPresent(Double.self,forKey:.strength) ?? 0.65
        style=try values.decodeIfPresent(Style.self,forKey:.style) ?? .frosted
        imageData=try values.decodeIfPresent(Data.self,forKey:.imageData)
    }
}
struct RedactionFrame: Codable, Equatable, Sendable {
    var time: Double
    var rect: NormalizedRect
}
struct RedactionTrack: Codable, Equatable, Sendable {
    var subjectID: UUID
    var frames: [RedactionFrame]
    var bodies: [RedactionFrame] = []
}
struct RedactionPlan: Codable, Equatable, Sendable {
    var subjects: [RedactionSubject]
    var region: RedactionSettings.Region
    var start: Double
    var end: Double
    var tracks: [RedactionTrack]
    var automaticTimes: [Double]? = nil
    var automaticPrimary: RedactionAnchor? = nil

    func covers(_ project:VideoProject) -> Bool {
        if project.settings.redaction.allOthers {
            guard let anchor=automaticPrimary,anchor.body==project.target,anchor.time==project.targetTime else {return false}
        }
        return covers(project.settings)
    }

    func covers(_ settings: EditSettings) -> Bool {
        let options = settings.redaction
        if options.allOthers {
            guard region == options.region, let times=automaticTimes, let first=times.first, let last=times.last,
                  first <= settings.start+0.001, last >= settings.end-0.001,
                  times.allSatisfy(\.isFinite), zip(times,times.dropFirst()).allSatisfy({$1>$0 && $1-$0<=0.151}) else {return false}
            return Set(tracks.map(\.subjectID)).count == tracks.count && tracks.allSatisfy { track in
                !track.frames.isEmpty && track.frames.allSatisfy {$0.time.isFinite && $0.rect.isValid && $0.time>=first-0.001 && $0.time<=last+0.001} &&
                zip(track.frames,track.frames.dropFirst()).allSatisfy {$1.time>$0.time && $1.time-$0.time<=0.151}
            }
        }
        guard automaticTimes == nil else {return false}
        guard subjects == options.subjects, region == options.region,
              start <= settings.start + 0.001, end >= settings.end - 0.001,
              tracks.count == subjects.count, Set(tracks.map(\.subjectID)) == Set(subjects.map(\.id)) else { return false }
        return tracks.allSatisfy { track in
            guard let a = track.frames.first, let b = track.frames.last,
                  a.time <= settings.start + 0.001, b.time >= settings.end - 0.001 else { return false }
            return track.frames.allSatisfy { $0.time.isFinite && $0.rect.isValid } &&
                zip(track.frames, track.frames.dropFirst()).allSatisfy { $1.time > $0.time && $1.time - $0.time <= 0.151 }
        }
    }
    func rectangles(at time: Double) -> [NormalizedRect] {
        tracks.compactMap { track in
            if automaticTimes != nil, let first=track.frames.first,let last=track.frames.last, (time<first.time || time>last.time) {return nil}
            return Self.rectangle(at: time, frames: track.frames)
        }
    }
    static func rectangle(at time: Double, frames: [RedactionFrame]) -> NormalizedRect? {
        guard time.isFinite, let first = frames.first, let last = frames.last else { return nil }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }
        var low = 0, high = frames.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if frames[middle].time <= time { low = middle } else { high = middle }
        }
        let a = frames[low], b = frames[high], u = (time-a.time)/(b.time-a.time)
        return .init(x:a.rect.x+(b.rect.x-a.rect.x)*u, y:a.rect.y+(b.rect.y-a.rect.y)*u,
                     width:a.rect.width+(b.rect.width-a.rect.width)*u, height:a.rect.height+(b.rect.height-a.rect.height)*u)
    }
}
struct RedactionIssue: Sendable {
    var subjectID: UUID
    var time: Double
    var message: String
}
struct RedactionAnalysisResult: Sendable {
    var plan: RedactionPlan?
    var issue: RedactionIssue?
}
enum RedactionError: LocalizedError {
    case incomplete, primaryTarget
    var errorDescription: String? {
        switch self {
        case .incomplete: "打码轨迹尚未确认完整，请完成打码人物识别后重试。"
        case .primaryTarget: "主角不参与打码，请调整打码人物后重试。"
        }
    }
}

/// Offline temporal envelope: short look-ahead, immediate expansion, slow contraction.
/// Always contains the observed region; no fading or delayed centre that could reveal a face.
enum RedactionMotion {
    static func smooth(_ input: [RedactionFrame]) -> [RedactionFrame] {
        let sorted = input.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }
        var envelopes = sorted.enumerated().map { index, frame -> CGRect in
            let neighbours = sorted[max(0,index-1)...min(sorted.count-1,index+1)]
            return neighbours.reduce(frame.rect.cgRect) { $0.union($1.rect.cgRect) }
        }
        for reverse in [false, true] {
            let indices = reverse ? Array(envelopes.indices.reversed()) : Array(envelopes.indices)
            var previous: CGRect?
            for index in indices {
                let raw = envelopes[index]
                if let old = previous {
                    // Keeping 65% of the old envelope smooths contraction without delaying coverage.
                    let left = min(raw.minX,old.minX*0.65+raw.minX*0.35)
                    let top = min(raw.minY,old.minY*0.65+raw.minY*0.35)
                    let right = max(raw.maxX,old.maxX*0.65+raw.maxX*0.35)
                    let bottom = max(raw.maxY,old.maxY*0.65+raw.maxY*0.35)
                    envelopes[index] = CGRect(x:left,y:top,width:right-left,height:bottom-top)
                }
                previous = envelopes[index]
            }
        }
        return zip(sorted,envelopes).map { frame, rect in
            .init(time:frame.time,rect:clamped(rect.insetBy(dx:-0.003,dy:-0.003)))
        }
    }
    static func clamped(_ rect: CGRect) -> NormalizedRect {
        let bounds = rect.intersection(CGRect(x:0,y:0,width:1,height:1))
        return .init(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height)
    }
    /// COCO nose/eyes/ears + shoulder span. Pixel geometry avoids stretched masks on portrait sources.
    /// Covers the head conservatively, including profile turns; no extra face network per person/frame.
    static func head(of person: PersonObservation, source: CGSize) -> NormalizedRect? {
        let face = person.keypoints.prefix(5).filter { $0.confidence >= 0.3 && $0.x.isFinite && $0.y.isFinite }
        guard !face.isEmpty else { return nil }
        let shoulders = [5,6].compactMap { person.keypoints.indices.contains($0) && person.keypoints[$0].confidence >= 0.4 ? person.keypoints[$0] : nil }
        let span = shoulders.count == 2 ? hypot((shoulders[0].x-shoulders[1].x)*source.width,(shoulders[0].y-shoulders[1].y)*source.height) : 0
        let xs = face.map { $0.x*source.width }, ys = face.map { $0.y*source.height }
        let side = max((xs.max()!-xs.min()!)*1.2,span*0.48,person.body.height*source.height*0.12)
        let cx = (xs.min()!+xs.max()!)/2, cy = (ys.min()!+ys.max()!)/2
        let rect = CGRect(x:(cx-side*0.65)/source.width,y:(cy-side*0.8)/source.height,width:side*1.3/source.width,height:side*1.55/source.height)
        let result = clamped(rect)
        return result.isValid ? result : nil
    }
    static func region(of person: PersonObservation, settings: RedactionSettings, source: CGSize) -> NormalizedRect? {
        if settings.region == .face { return head(of:person,source:source) }
        let body = person.protectionBody.cgRect
        return clamped(body.insetBy(dx:-body.width*0.07,dy:-body.height*0.035))
    }
}

/// The followed subject is always excluded from redaction selection and stored recipes.
enum RedactionPolicy {
    static func primaryBody(project:VideoProject,time:Double,samples:[TargetSample]) -> NormalizedRect? {
        if let first=samples.first,let last=samples.last,time>=first.time-0.001,time<=last.time+0.001 {
            return RedactionPlan.rectangle(at:time,frames:samples.map {.init(time:$0.time,rect:$0.body)})
        }
        return abs(time-project.targetTime)<0.06 ? project.target : nil
    }
    static func conflicts(project:VideoProject,samples:[TargetSample]) -> Set<UUID> {
        Set(project.settings.redaction.subjects.filter {subject in
            subject.anchors.contains {anchor in
                primaryBody(project:project,time:anchor.time,samples:samples).map {$0.iou(anchor.body)>0.6} ?? false
            }
        }.map(\.id))
    }
}
