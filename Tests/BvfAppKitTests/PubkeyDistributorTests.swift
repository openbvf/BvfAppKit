import Testing
import Foundation
@testable import BvfAppKitDecrypt
@testable import BvfAppKit

@Suite(.serialized)
@MainActor
struct PubkeyDistributorTests {

    private func makeCloudManager(containerDir: URL) -> iCloudManager {
        let cm = iCloudManager("test", container: "test.container")
        cm.containerURL = containerDir
        cm.isAvailable = true
        return cm
    }

    @Test func publish_whenRemoteDiffers_doesNotOverwrite_andSetsMismatch() async throws {
        let localDir = TestFileHelper.createTestDirectory()
        let containerDir = TestFileHelper.createTestDirectory()
        defer {
            TestFileHelper.removeTestDirectory(localDir)
            TestFileHelper.removeTestDirectory(containerDir)
        }

        let cloudManager = makeCloudManager(containerDir: containerDir)
        guard let remoteURL = cloudManager.sharedPublicKeyURL else {
            Issue.record("sharedPublicKeyURL is nil")
            return
        }

        // Create the remote key file (key A) at the expected iCloud location
        try FileManager.default.createDirectory(
            at: remoteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("key-A".utf8).write(to: remoteURL)

        // Local key file (key B) — different from remote
        let localURL = localDir.appendingPathComponent("public.key")
        try Data("key-B".utf8).write(to: localURL)

        let fileAccess = FileAccessManager(cloudManager: cloudManager, appGroupIdentifier: "group.test.nonexistent")
        fileAccess.savedFiles[FileAccessManager.publicKeyBookmarkKey] = localURL

        let distributor = PubkeyDistributor(cloudManager: cloudManager, fileAccessManager: fileAccess)

        // publish() should detect mismatch and not overwrite remote
        try distributor.publish()

        let remoteBytes = try Data(contentsOf: remoteURL)
        #expect(remoteBytes == Data("key-A".utf8), "Remote should remain unchanged")
        #expect(distributor.pubkeyMismatch != nil, "pubkeyMismatch should be set")
    }

    @Test func confirmOverwrite_whenWriteFails_retainsMismatch_andThrows() async throws {
        let localDir = TestFileHelper.createTestDirectory()
        let containerDir = TestFileHelper.createTestDirectory()
        defer {
            TestFileHelper.removeTestDirectory(localDir)
            TestFileHelper.removeTestDirectory(containerDir)
        }

        let cloudManager = makeCloudManager(containerDir: containerDir)
        guard let remoteURL = cloudManager.sharedPublicKeyURL else {
            Issue.record("sharedPublicKeyURL is nil")
            return
        }

        // Create the remote key file
        let remoteParent = remoteURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: remoteParent, withIntermediateDirectories: true)
        try Data("key-A".utf8).write(to: remoteURL)

        // Local key file — different from remote
        let localURL = localDir.appendingPathComponent("public.key")
        try Data("key-B".utf8).write(to: localURL)

        let fileAccess = FileAccessManager(cloudManager: cloudManager, appGroupIdentifier: "group.test.nonexistent")
        fileAccess.savedFiles[FileAccessManager.publicKeyBookmarkKey] = localURL

        let distributor = PubkeyDistributor(cloudManager: cloudManager, fileAccessManager: fileAccess)

        // Simulate a detected mismatch
        distributor.pubkeyMismatch = PubkeyMismatch(localURL: localURL, remoteURL: remoteURL)

        // Make the remote parent directory read-only so the write will fail
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: remoteParent.path
        )
        defer {
            // Restore permissions so the outer defer can remove containerDir
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: remoteParent.path
            )
        }

        // confirmOverwrite() should throw and retain pubkeyMismatch
        #expect(throws: (any Error).self) {
            try distributor.confirmOverwrite()
        }
        #expect(distributor.pubkeyMismatch != nil, "pubkeyMismatch should be retained on failure")
    }
}
