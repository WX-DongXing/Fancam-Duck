import Foundation
import XCTest

/// Real-video integration tests use an explicitly supplied local file, never a bundled video.
enum TestVideoFixture {
    static func people() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FANCAM_DUCK_TEST_VIDEO"], !path.isEmpty else {
            throw XCTSkip("Set FANCAM_DUCK_TEST_VIDEO to a local test video; video files are not distributed with this repository.")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("The configured local test video is unavailable.")
        }
        return url
    }
}
