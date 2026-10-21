import XCTest
@testable import FancamDuck

private actor ImportReadGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private(set) var started=false
    func wait() async {await withCheckedContinuation {started=true;continuation=$0}}
    func release() {continuation?.resume();continuation=nil}
}

@MainActor final class ProjectIntegrityTests:XCTestCase {
    private var root:URL!
    private var store:ProjectStore!
    override func setUp() async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store=ProjectStore(directory:root);try await store.prepare()
    }
    override func tearDown() async throws {try? FileManager.default.removeItem(at:root)}
    private func project(redacted:Bool) async throws -> VideoProject {
        let source=root.appendingPathComponent("source.mp4")
        try Data("Synthetic source bytes for persistence tests".utf8).write(to:source)
        var project=VideoProject(title:"Persistence fixture",sourceFileName:source.lastPathComponent,
            metadata:.init(width:64,height:64,duration:1,frameRate:30),settings:EditSettings())
        project.settings.end=1;project.settings.redaction.allOthers=redacted
        if redacted {
            project.target = .init(x:0.2,y:0.2,width:0.2,height:0.5)
            project.redactionPlan = .init(subjects:[],region:.face,start:0,end:1,tracks:[],
                automaticTimes:(0...6).map {Double($0)/6},automaticPrimary:.init(time:project.targetTime,body:project.target!))
        }
        try await store.save(project)
        return project
    }
    private func rewriteManifest(_ project:VideoProject,change:(inout [String:Any])->Void) throws {
        let manifest=root.appendingPathComponent("artifacts-\(project.id)/output.json")
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        change(&value)
        try JSONSerialization.data(withJSONObject:value).write(to:manifest,options:.atomic)
    }
    func testReopeningCannotReuseOutputFromAnOlderRedactionRenderer() async throws {
        let project=try await project(redacted:true)
        let output=try await store.saveOutput(project:project,url:try XCTUnwrap(store.sourceURL(for:project)))
        let current=try await ProjectStore(directory:root).output(for:project)
        XCTAssertEqual(current?.url,output)
        try rewriteManifest(project) {$0.removeValue(forKey:"redactionVersion")}
        let legacy=try await ProjectStore(directory:root).output(for:project)
        XCTAssertNil(legacy,"Rebuilding a current plan cannot turn an old movie into a current render")
        try rewriteManifest(project) {$0["redactionVersion"]=RedactionPlan.currentSmoothingVersion-1}
        let obsolete=try await ProjectStore(directory:root).output(for:project)
        XCTAssertNil(obsolete)
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path),"Keep the previous movie available as a file")
    }
    func testLegacyUnredactedOutputStillRestores() async throws {
        let project=try await project(redacted:false)
        let output=try await store.saveOutput(project:project,url:try XCTUnwrap(store.sourceURL(for:project)))
        try rewriteManifest(project) {$0.removeValue(forKey:"redactionVersion")}
        let restored=try await ProjectStore(directory:root).output(for:project)
        XCTAssertEqual(restored?.url,output)
    }
    func testReplacingOutputDoesNotDeleteOutsideItsArtifactsDirectory() async throws {
        let project=try await project(redacted:false)
        let source=try XCTUnwrap(store.sourceURL(for:project))
        _=try await store.saveOutput(project:project,url:source)
        let keep=root.appendingPathComponent("keep.bin")
        try Data("Keep this file".utf8).write(to:keep)
        try rewriteManifest(project) {$0["fileName"]="../keep.bin"}
        _=try await store.saveOutput(project:project,url:source)
        XCTAssertTrue(FileManager.default.fileExists(atPath:keep.path))
        try rewriteManifest(project) {$0["fileName"]="output.json"}
        let newOutput=try await store.saveOutput(project:project,url:source)
        let restored=try await store.output(for:project)
        XCTAssertEqual(restored?.url,newOutput,"Replacing a corrupt record must not delete the newly written manifest")
    }
    private func started(_ gate:ImportReadGate) async throws {
        for _ in 0..<100 {if await gate.started {return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Import loader did not start")
    }
    func testLatePhotoReadCannotReplaceTheNewerImportOrClearItsBusyState() async throws {
        let model=AppModel(store:store),firstGate=ImportReadGate(),secondGate=ImportReadGate()
        let firstFile=root.appendingPathComponent("transfer.tmp")
        try Data("Not a movie: a stale transfer must never reach metadata loading".utf8).write(to:firstFile)
        let first=Task {await model.importMovie(load:{await firstGate.wait();return ImportedMovie(url:firstFile)})}
        try await started(firstGate)
        let second=Task {await model.importMovie(load:{await secondGate.wait();throw NSError(domain:"Latest selection",code:7)})}
        try await started(secondGate)
        await firstGate.release();await first.value
        XCTAssertTrue(model.importing)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath:firstFile.path))
        let projects=try await store.projects();XCTAssertTrue(projects.isEmpty)
        await secondGate.release();await second.value
        XCTAssertFalse(model.importing)
        XCTAssertTrue(model.errorMessage?.contains("Latest selection") == true)
    }
    func testLeavingDuringPhotoReadRejectsItsLateError() async throws {
        let model=AppModel(store:store),gate=ImportReadGate()
        let task=Task {await model.importMovie(load:{await gate.wait();throw NSError(domain:"Old selection",code:8)})}
        try await started(gate)
        model.startDemo()
        await gate.release();await task.value
        XCTAssertTrue(model.isDemo)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.importing)
        model.goHome()
    }
}
