import Foundation

/// Shared sampling contract for tracking, cache coverage and redaction reuse.
enum AnalysisSampling {
    static let frequency:Double=6
    static let interval:Double=1/frequency
    static let maximumSampleGap:Double=interval+0.002
    static func key(_ time:Double)->Int {Int((time*10000).rounded())}
}
struct AnalysisReviewFrame:Codable,Equatable,Sendable,Identifiable {
    let time:Double
    var body:NormalizedRect?
    var id:Int {AnalysisSampling.key(time)}
}
struct AnalysisReview:Codable,Sendable {
    var frames:[AnalysisReviewFrame]
    var samples:[TargetSample]
    var people:[Int:DetectionBatch]
    var detected:Set<Int>=[]
    var pending:[AnalysisReviewFrame] {frames.filter {$0.body == nil}}
    mutating func confirm(time:Double,box:NormalizedRect)->Bool {
        guard box.isValid,box.width>0.015,box.height>0.03,
              let index=frames.firstIndex(where:{$0.id==AnalysisSampling.key(time)}) else {return false}
        frames[index].body=box
        samples.removeAll {AnalysisSampling.key($0.time)==frames[index].id}
        samples.append(.init(time:frames[index].time,body:box,protection:box))
        samples.sort {$0.time<$1.time}
        return true
    }
}
