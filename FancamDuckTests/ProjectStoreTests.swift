import XCTest
@testable import FancamDuck

final class ProjectStoreTests: XCTestCase {
    func testDeletingProjectOnlyRemovesOwnedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.mov")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: original)
        let store = ProjectStore(directory: root.appendingPathComponent("Fancam Duck"))
        let owned = try await store.importFile(original)
        var project = VideoProject.demo
        project.isDemo = false
        project.sourceFileName = owned.lastPathComponent
        try await store.save(project)
        let loaded = try await store.projects()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, project.id)
        try await store.remove(project)
        let remaining = try await store.projects()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
    func testBrandRenameMigratesLegacyProjectsAndOwnedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("AICut")
        let current = root.appendingPathComponent("Fancam Duck")
        let oldStore = ProjectStore(directory: legacy)
        var project = VideoProject.demo
        project.isDemo = false
        project.sourceFileName = "source.mov"
        try await oldStore.save(project)
        let source = Data([1, 2, 3, 4])
        try source.write(to: legacy.appendingPathComponent("source.mov"))
        let renamed = ProjectStore(directory: current, legacyDirectory: legacy)
        let projects = try await renamed.projects()
        XCTAssertEqual(projects.map(\.id), [project.id])
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("source.mov")), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let reopened = try await renamed.projects()
        XCTAssertEqual(reopened.count, 1)
    }

    func testBrandRenamePreservesBothDirectoriesWhenDestinationAlreadyExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("AICut")
        let current = root.appendingPathComponent("Fancam Duck")
        let oldStore = ProjectStore(directory: legacy)
        let currentStore = ProjectStore(directory: current)
        var oldProject = VideoProject.demo
        oldProject.title = "Legacy project"
        let newProject = VideoProject.demo
        try await oldStore.save(oldProject)
        try await currentStore.save(newProject)
        let renamed = ProjectStore(directory: current, legacyDirectory: legacy)
        let projects = try await renamed.projects()
        XCTAssertEqual(projects.map(\.id), [newProject.id])
        let oldProjects = try await oldStore.projects()
        XCTAssertEqual(oldProjects.map(\.id), [oldProject.id])
    }
}
