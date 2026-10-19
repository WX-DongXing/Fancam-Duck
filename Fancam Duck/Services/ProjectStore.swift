import Foundation
import CryptoKit

actor ProjectStore {
    static let shared = ProjectStore()
    nonisolated let directory: URL
    private let legacyDirectory: URL?
    init(directory: URL? = nil, legacyDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("Fancam Duck", isDirectory: true)
        self.legacyDirectory = legacyDirectory ?? (directory == nil ? support.appendingPathComponent("AICut", isDirectory: true) : nil)
    }
    func prepare() throws {
        if let legacyDirectory, legacyDirectory != directory,
           !FileManager.default.fileExists(atPath: directory.path),
           FileManager.default.fileExists(atPath: legacyDirectory.path) {
            try FileManager.default.moveItem(at: legacyDirectory, to: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func projects() throws -> [VideoProject] {
        try prepare()
        let index = directory.appendingPathComponent("projects.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([VideoProject].self, from: Data(contentsOf: index)).sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ project: VideoProject) throws {
        var all = try projects()
        all.removeAll { $0.id == project.id }
        all.insert(project, at: 0)
        try JSONEncoder().encode(all).write(to: directory.appendingPathComponent("projects.json"), options: .atomic)
    }
    func remove(_ project: VideoProject) throws {
        let outputDirectory=artifactsURL(project.id)
        if FileManager.default.fileExists(atPath:outputDirectory.path) {try FileManager.default.removeItem(at:outputDirectory)}
        let cache=trajectoryURL(project.id)
        if FileManager.default.fileExists(atPath:cache.path) {try FileManager.default.removeItem(at:cache)}
        let all = try projects().filter { $0.id != project.id }
        try JSONEncoder().encode(all).write(to: directory.appendingPathComponent("projects.json"), options: .atomic)
        if let name = project.sourceFileName, !all.contains(where: { $0.sourceFileName == name }) {
            let source = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        }
    }
    private struct TrajectoryRecord:Codable {
        let version:String
        let sourceDigest:String
        let sourceFileName:String?
        let metadata:VideoMetadata
        let target:NormalizedRect?
        let targetTime:Double
        let samples:[TargetSample]
    }
    // Bump when inference preprocessing, identity matching or occlusion policy changes.
    static let analysisVersion="yolo26s640-osnet025-tracktrack10hz-bridge12-v1"
    private struct DigestEntry {let size:UInt64;let date:Date;let digest:String}
    private var digests:[URL:DigestEntry]=[:]
    private func trajectoryURL(_ id:UUID) -> URL {directory.appendingPathComponent("trajectory-\(id).json")}
    private func digest(_ source:URL) throws -> String {
        let attributes=try FileManager.default.attributesOfItem(atPath:source.path)
        let size=(attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let date=attributes[.modificationDate] as? Date ?? .distantPast
        if let cached=digests[source],cached.size==size,cached.date==date {return cached.digest}
        let handle=try FileHandle(forReadingFrom:source);defer {try? handle.close()}
        var hash=SHA256()
        while let data=try handle.read(upToCount:1024*1024),!data.isEmpty {hash.update(data:data)}
        let value=hash.finalize().map {String(format:"%02x",$0)}.joined()
        digests[source] = .init(size:size,date:date,digest:value);return value
    }
    func saveTrajectory(project:VideoProject,samples:[TargetSample]) throws {
        guard !project.isDemo,let source=sourceURL(for:project),try projects().contains(where:{$0.id==project.id}) else {return}
        try VideoExporter.validateTrajectory(samples,project:project)
        let record=TrajectoryRecord(version:Self.analysisVersion,sourceDigest:try digest(source),sourceFileName:project.sourceFileName,metadata:project.metadata,target:project.target,targetTime:project.targetTime,samples:samples)
        try JSONEncoder().encode(record).write(to:trajectoryURL(project.id),options:.atomic)
    }
    func trajectory(for project:VideoProject) throws -> [TargetSample]? {
        guard let source=sourceURL(for:project),let data=try? Data(contentsOf:trajectoryURL(project.id)),
              let record=try? JSONDecoder().decode(TrajectoryRecord.self,from:data),record.version==Self.analysisVersion,
              record.sourceFileName==project.sourceFileName,record.metadata==project.metadata,
              record.target==project.target,record.targetTime==project.targetTime,
              record.sourceDigest == (try digest(source)),
              (try? VideoExporter.validateTrajectory(record.samples,project:project)) != nil else {return nil}
        return record.samples
    }
    struct StoredOutput:Sendable {let url:URL;let savedToPhotos:Bool}
    private struct OutputRecord:Codable {
        let sourceDigest:String
        let sourceFileName:String?
        let metadata:VideoMetadata
        let settings:EditSettings
        let target:NormalizedRect?
        let targetTime:Double
        let fileName:String
        var savedToPhotos:Bool
        func matches(_ project:VideoProject) -> Bool {
            sourceFileName==project.sourceFileName && metadata==project.metadata && settings==project.settings && target==project.target && targetTime==project.targetTime
        }
    }
    private func artifactsURL(_ id:UUID) -> URL {directory.appendingPathComponent("artifacts-\(id)",isDirectory:true)}
    func saveOutput(project:VideoProject,url:URL) throws -> URL {
        guard let source=sourceURL(for:project),try projects().contains(where:{$0.id==project.id}) else {throw CancellationError()}
        let folder=artifactsURL(project.id);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let manifest=folder.appendingPathComponent("output.json")
        let old=(try? Data(contentsOf:manifest)).flatMap {try? JSONDecoder().decode(OutputRecord.self,from:$0)}
        let destination=folder.appendingPathComponent(UUID().uuidString+".mp4")
        try FileManager.default.copyItem(at:url,to:destination)
        do {
            let record=OutputRecord(sourceDigest:try digest(source),sourceFileName:project.sourceFileName,metadata:project.metadata,settings:project.settings,target:project.target,targetTime:project.targetTime,fileName:destination.lastPathComponent,savedToPhotos:false)
            try JSONEncoder().encode(record).write(to:manifest,options:.atomic)
        } catch {try? FileManager.default.removeItem(at:destination);throw error}
        if let old,old.fileName != destination.lastPathComponent {try? FileManager.default.removeItem(at:folder.appendingPathComponent(old.fileName))}
        return destination
    }
    func output(for project:VideoProject) throws -> StoredOutput? {
        let folder=artifactsURL(project.id)
        guard let source=sourceURL(for:project),let data=try? Data(contentsOf:folder.appendingPathComponent("output.json")),
              let record=try? JSONDecoder().decode(OutputRecord.self,from:data),record.matches(project),
              record.fileName==URL(fileURLWithPath:record.fileName).lastPathComponent,
              record.sourceDigest == (try digest(source)) else {return nil}
        let file=folder.appendingPathComponent(record.fileName)
        guard FileManager.default.fileExists(atPath:file.path) else {return nil}
        return .init(url:file,savedToPhotos:record.savedToPhotos)
    }
    func markOutputSaved(project:VideoProject,url:URL) throws {
        let manifest=artifactsURL(project.id).appendingPathComponent("output.json")
        guard let data=try? Data(contentsOf:manifest),var record=try? JSONDecoder().decode(OutputRecord.self,from:data),record.matches(project),record.fileName==url.lastPathComponent else {return}
        record.savedToPhotos=true;try JSONEncoder().encode(record).write(to:manifest,options:.atomic)
    }
    func importFile(_ url: URL) throws -> URL {
        try prepare()
        let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        let output = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: output)
        return output
    }
    nonisolated func sourceURL(for project: VideoProject) -> URL? {
        project.sourceFileName.map { directory.appendingPathComponent($0) }
    }
}
