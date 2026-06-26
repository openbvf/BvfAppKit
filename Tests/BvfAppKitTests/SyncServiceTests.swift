import Testing
import Foundation
@testable import BvfAppKitDecrypt
@testable import BvfAppKit

@Suite(.serialized)
struct SyncServiceTests {

    /// Create a test directory with the real path (not through /var symlink).
    /// NSFileManager.enumerator returns paths under /private/var, so the source URL must match
    /// for the relative path computation in SyncService to work correctly.
    private func realTestDirectory() -> URL {
        let dir = TestFileHelper.createTestDirectory()
        // realpath resolves /var → /private/var on macOS
        let cPath = dir.path.withCString { realpath($0, nil)! }
        defer { free(cPath) }
        return URL(fileURLWithPath: String(cString: cPath))
    }

    @Test func testBouncedFileGetsValidPath() async throws {
        let iCloudDir = realTestDirectory()
        let localDir = realTestDirectory()
        defer {
            TestFileHelper.removeTestDirectory(iCloudDir)
            TestFileHelper.removeTestDirectory(localDir)
        }

        // Simulate an iCloud-bounced file: "14.23.45.123 2.txt.bvf"
        let dateDir = iCloudDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let bouncedFile = dateDir.appendingPathComponent("14.23.45.123 2.txt.bvf")
        try "encrypted data".data(using: .utf8)!.write(to: bouncedFile)

        let service = SyncService()
        let result = try await service.sync(from: iCloudDir, to: localDir)

        #expect(result.filesCopied == 1, "Bounced file should be copied")
        #expect(result.errors.isEmpty, "No errors expected")

        // Verify the file landed at a valid path, not the bounced name
        let localDateDir = localDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        let localFiles = try FileManager.default.contentsOfDirectory(
            at: localDateDir, includingPropertiesForKeys: nil
        )
        #expect(localFiles.count == 1, "Exactly one file should exist locally")

        let filename = localFiles[0].lastPathComponent
        #expect(!filename.contains(" "), "Local filename should not contain a space")
        #expect(filename.hasSuffix(".txt.bvf"), "Suffix should be preserved")
        #expect(filename.hasPrefix("14.23.45."), "Timestamp prefix should be preserved")
    }

    @Test func testBouncedFileWithoutSuffix() async throws {
        let iCloudDir = realTestDirectory()
        let localDir = realTestDirectory()
        defer {
            TestFileHelper.removeTestDirectory(iCloudDir)
            TestFileHelper.removeTestDirectory(localDir)
        }

        // Bounced file with no suffix: "14.23.45.123 2.bvf"
        let dateDir = iCloudDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let bouncedFile = dateDir.appendingPathComponent("14.23.45.123 2.bvf")
        try "encrypted data".data(using: .utf8)!.write(to: bouncedFile)

        let service = SyncService()
        let result = try await service.sync(from: iCloudDir, to: localDir)

        #expect(result.filesCopied == 1)
        #expect(result.errors.isEmpty)

        let localDateDir = localDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        let localFiles = try FileManager.default.contentsOfDirectory(
            at: localDateDir, includingPropertiesForKeys: nil
        )
        #expect(localFiles.count == 1)

        let filename = localFiles[0].lastPathComponent
        #expect(!filename.contains(" "))
        #expect(filename.hasSuffix(".bvf"))
        #expect(filename.hasPrefix("14.23.45."))
    }

    @Test func testNormalFileUnaffected() async throws {
        let iCloudDir = realTestDirectory()
        let localDir = realTestDirectory()
        defer {
            TestFileHelper.removeTestDirectory(iCloudDir)
            TestFileHelper.removeTestDirectory(localDir)
        }

        // Normal file, no bounce
        let dateDir = iCloudDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let normalFile = dateDir.appendingPathComponent("14.23.45.123.txt.bvf")
        try "encrypted data".data(using: .utf8)!.write(to: normalFile)

        let service = SyncService()
        let result = try await service.sync(from: iCloudDir, to: localDir)

        #expect(result.filesCopied == 1)
        #expect(result.errors.isEmpty)

        let localDateDir = localDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        let localFiles = try FileManager.default.contentsOfDirectory(
            at: localDateDir, includingPropertiesForKeys: nil
        )
        #expect(localFiles.count == 1)
        #expect(localFiles[0].lastPathComponent == "14.23.45.123.txt.bvf")
    }

    @Test func testBouncedFileWithOriginalPresent() async throws {
        let iCloudDir = realTestDirectory()
        let localDir = realTestDirectory()
        defer {
            TestFileHelper.removeTestDirectory(iCloudDir)
            TestFileHelper.removeTestDirectory(localDir)
        }

        // Both the original and the bounced file exist in iCloud
        let dateDir = iCloudDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let original = dateDir.appendingPathComponent("14.23.45.123.txt.bvf")
        try "original data".data(using: .utf8)!.write(to: original)

        let bounced = dateDir.appendingPathComponent("14.23.45.123 2.txt.bvf")
        try "bounced data".data(using: .utf8)!.write(to: bounced)

        let service = SyncService()
        let result = try await service.sync(from: iCloudDir, to: localDir)

        #expect(result.filesCopied == 2, "Both files should be copied")
        #expect(result.errors.isEmpty)

        let localDateDir = localDir
            .appendingPathComponent("2024")
            .appendingPathComponent("06")
            .appendingPathComponent("15")
        let localFiles = try FileManager.default.contentsOfDirectory(
            at: localDateDir, includingPropertiesForKeys: nil
        )
        #expect(localFiles.count == 2, "Both files should exist with unique paths")

        // Neither should contain a space
        for file in localFiles {
            #expect(!file.lastPathComponent.contains(" "))
        }
    }
}
