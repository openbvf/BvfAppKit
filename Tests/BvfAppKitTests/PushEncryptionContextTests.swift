import Testing
import Foundation
import BvfKit
@testable import BvfAppKit

@Suite(.serialized)
struct PushEncryptionContextTests {

    private func createTestPublicKeyFile(in directory: URL) throws -> URL {
        let keypair = try Keypair.generate()
        let keyURL = directory.appendingPathComponent("test_public.pub")
        try keypair.publicKey.write(to: keyURL, atomically: true, encoding: .utf8)
        return keyURL
    }

    @Test func testTwoInitsAtSameMillisecondProduceDifferentStagingPaths() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try createTestPublicKeyFile(in: testDir)
        let destDir = testDir.appendingPathComponent("dest")
        let stagingRoot = testDir.appendingPathComponent("staging", isDirectory: true)

        let fixedDate = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15, hour: 10, minute: 0, second: 0, nanosecond: 0
        ))!

        let ctx1 = try PushEncryptionContext(
            publicKeyURL: publicKeyURL, to: destDir, date: fixedDate, suffix: "m4a", stagingURL: stagingRoot
        )
        let ctx2 = try PushEncryptionContext(
            publicKeyURL: publicKeyURL, to: destDir, date: fixedDate, suffix: "m4a", stagingURL: stagingRoot
        )

        defer {
            _ = try? ctx1.finish()
            _ = try? ctx2.finish()
        }

        // Test-owned staging root: every .bvf in here came from this test.
        let stagedFiles = (try? FileManager.default.subpathsOfDirectory(atPath: stagingRoot.path)) ?? []
        let bvfFiles = stagedFiles.filter { $0.hasSuffix(".bvf") }
        #expect(bvfFiles.count == 2,
                "Two PushEncryptionContext inits at the same millisecond should create 2 distinct staging files, got: \(bvfFiles)")
    }
}
