import XCTest
@testable import FancamDuck

final class InferenceEfficiencyTests:XCTestCase {
    func testFeaturePolicyRetainsLowPrimaryAndOnlyUsedRelaxedProposals() {
        func d(_ id:Int,_ score:Float) -> PersonObservation {
            .init(id:id,body:.init(x:0.2,y:0.1,width:0.3,height:0.7),confidence:score)
        }
        let primary=[d(1,0.9),d(2,0.2)],relaxed=primary+[d(3,0.7),d(4,0.5),d(5,0.1)]
        XCTAssertEqual(CoreMLPeopleModels.featureCandidateIDs(primary:primary,relaxed:relaxed,threshold:0.5),Set([1,2,3]))
        XCTAssertEqual(CoreMLPeopleModels.featureCandidateIDs(primary:primary,relaxed:relaxed,threshold:0.1),Set([1,2,3,4]))
    }
    func testVectorDistanceMatchesScalarReference() {
        let a=Appearance.normalized((0..<512).map {Float(sin(Double($0)*0.17))})
        let b=Appearance.normalized((0..<512).map {Float(sin(Double($0)*0.19))})
        let expected=min(1,max(0,1-zip(a,b).reduce(0.0) {$0+Double($1.0*$1.1)}))
        XCTAssertEqual(Appearance.distance(a,b),expected,accuracy:0.000001)
        XCTAssertEqual(Appearance.distance(a,a),0,accuracy:0.000001)
        XCTAssertEqual(Appearance.distance([],b),1)
    }
    func testPooledBuffersPreserveActualPoseAndIdentityFeatures() async throws {
        let source=try TestVideoFixture.people()
        let original=try CoreMLPeopleModels(reuseBuffers:false),pooled=try CoreMLPeopleModels(reuseBuffers:true)
        let image=try await original.image(source:source,time:0)
        let expected=try original.detect(image,features:true)
        for _ in 0..<3 {
            let result=try pooled.detect(image,features:true)
            XCTAssertEqual(result.primary.map(\.body),expected.primary.map(\.body))
            for p in result.primary {
                let reference=try XCTUnwrap(expected.primary.first {$0.id==p.id})
                XCTAssertEqual(p.keypoints,reference.keypoints)
                XCTAssertLessThan(Appearance.distance(p.embedding,reference.embedding),0.00001)
            }
        }
        XCTAssertEqual(pooled.metrics.bufferAllocations,0);XCTAssertGreaterThan(pooled.metrics.poolRequests,0)
    }
    func testActualRetainedFeaturesAreUnchangedBySkippingUnusedProposals() async throws {
        let source=try TestVideoFixture.people()
        let engine=try CoreMLPeopleModels(),image=try await engine.image(source:source,time:0)
        let original=try engine.detect(image,features:true,relaxedFeatureThreshold:-1)
        let optimized=try engine.detect(image,features:true)
        XCTAssertEqual(original.primary.map(\.body),optimized.primary.map(\.body))
        let used=CoreMLPeopleModels.featureCandidateIDs(primary:optimized.primary,relaxed:optimized.relaxed,threshold:0.5)
        for candidate in optimized.relaxed {
            let reference=try XCTUnwrap(original.relaxed.first {$0.id==candidate.id})
            if used.contains(candidate.id) {
                XCTAssertEqual(candidate.embedding.count,512)
                XCTAssertLessThan(Appearance.distance(reference.embedding,candidate.embedding),0.00001)
            } else { XCTAssertTrue(candidate.embedding.isEmpty) }
        }
    }
}

private actor PreviewTimes {
    var frames:[Double]=[]
    func record(_ update:TrackingUpdate) {if update.preview != nil {frames.append(update.sample.time)}}
}
extension InferenceEfficiencyTests {
    func testDisplayThrottlingKeepsActualAnalysisAndFinalPreviewUnchanged() async throws {
        let source=try TestVideoFixture.people()
        let original=CoreMLTrackingPipeline(reuseBuffers:false,previewInterval:0),optimized=CoreMLTrackingPipeline()
        let people=try await original.detections(source:source,time:0,region:nil)
        var project=VideoProject(title:"Preview parity",metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        project.settings.end=0.7;project.target=try XCTUnwrap(people.max {$0.body.height<$1.body.height}).body
        _=try await optimized.detections(source:source,time:0,region:nil)
        let oldTimes=PreviewTimes(),newTimes=PreviewTimes()
        let before=try await original.analyze(source:source,project:project) {await oldTimes.record($0)}
        let after=try await optimized.analyze(source:source,project:project) {await newTimes.record($0)}
        XCTAssertNil(before.issue);XCTAssertNil(after.issue);XCTAssertEqual(before.samples,after.samples)
        let a=await oldTimes.frames,b=await newTimes.frames
        XCTAssertLessThan(b.count,a.count);XCTAssertEqual(b.last,0.7)
        let oldMetrics=await original.performanceMetrics(),newMetrics=await optimized.performanceMetrics()
        XCTAssertEqual(oldMetrics?.poseCalls,newMetrics?.poseCalls);XCTAssertEqual(oldMetrics?.reidCalls,newMetrics?.reidCalls)
    }
}
