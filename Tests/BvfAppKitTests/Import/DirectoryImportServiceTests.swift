import Testing
import Foundation
import CryptoKit
import BvfKit
@testable import BvfAppKitDecrypt
@testable import BvfAppKit

@Suite(.serialized)
struct DirectoryImportServiceTests {

    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ImportProgress] = []

        func record(_ event: ImportProgress) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var snapshot: [ImportProgress] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0

        /// Returns true on the very first call (caller treats this as the failing attempt).
        func recordAndCheckFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            attempts += 1
            return attempts == 1
        }
    }

    private final class ConfirmCallTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0

        func record() {
            lock.lock()
            _count += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
    }

    private final class ReceivedInfos: @unchecked Sendable {
        private let lock = NSLock()
        private var infos: [ImportedFileInfo] = []

        func set(_ value: [ImportedFileInfo]) {
            lock.lock()
            infos = value
            lock.unlock()
        }

        var snapshot: [ImportedFileInfo] {
            lock.lock(); defer { lock.unlock() }
            return infos
        }
    }

    private func makePublicKey(in directory: URL) throws -> URL {
        let keypair = try Keypair.generate()
        let keyURL = directory.appendingPathComponent("test_public.pub")
        try keypair.publicKey.write(to: keyURL, atomically: true, encoding: .utf8)
        return keyURL
    }

    private func findEncryptedFiles(under destination: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var results: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "bvf" {
                results.append(url)
            }
        }
        return results
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }


    @Test func singleFileImportSucceeds() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("source.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "hello world")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()
        let collector = ProgressCollector()

        let result = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            onProgress: { collector.record($0) }
        )

        #expect(result.imported.count == 1)
        #expect(result.failed.isEmpty)
        #expect(result.skipped.isEmpty)
        #expect(result.importedInfo.count == 1)

        let info = result.importedInfo[0]
        #expect(info.sourceURL == sourceURL)
        #expect(info.relativePath == "source.txt")
        #expect(info.wasProcessed == false)
        #expect(info.sourceContentHash == nil)

        let encrypted = findEncryptedFiles(under: destination)
        #expect(encrypted.count == 1)
        let data = try Data(contentsOf: encrypted[0])
        #expect(data.starts(with: Data("bvf-v1\n".utf8)))
    }

    @Test func nestedDirectoryImportPreservesRelativePaths() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceRoot = testDir.appendingPathComponent("source")
        let a = sourceRoot.appendingPathComponent("photos/2024/IMG_1.jpg")
        let b = sourceRoot.appendingPathComponent("photos/2025/IMG_2.jpg")
        try TestFileHelper.createTestFile(at: a, content: "a")
        try TestFileHelper.createTestFile(at: b, content: "b")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()
        let result = try await service.importFiles(
            [sourceRoot],
            to: destination,
            publicKeyURL: publicKeyURL,
            rootURL: sourceRoot,
            onProgress: { _ in }
        )

        #expect(result.imported.count == 2)
        let paths = Set(result.importedInfo.map(\.relativePath))
        #expect(paths == Set(["photos/2024/IMG_1.jpg", "photos/2025/IMG_2.jpg"]))
    }

    @Test func tagsDerivedFromFolderHierarchyAndFilename() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceRoot = testDir.appendingPathComponent("source")
        let nested = sourceRoot.appendingPathComponent("vacation/2025/IMG_42.jpg")
        try TestFileHelper.createTestFile(at: nested, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()
        let result = try await service.importFiles(
            [sourceRoot],
            to: destination,
            publicKeyURL: publicKeyURL,
            rootURL: sourceRoot,
            onProgress: { _ in }
        )

        #expect(result.importedInfo.count == 1)
        let tags = ImportTagsHelper.tagsFor(info: result.importedInfo[0])
        #expect(tags == ["vacation", "2025", "IMG_42"])
    }

    @Test func fileFilterSeparatesIncludedAndSkipped() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceRoot = testDir.appendingPathComponent("source")
        let txt = sourceRoot.appendingPathComponent("keep.txt")
        let log = sourceRoot.appendingPathComponent("drop.log")
        try TestFileHelper.createTestFile(at: txt, content: "k")
        try TestFileHelper.createTestFile(at: log, content: "d")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        let result = try await service.importFiles(
            [sourceRoot],
            to: destination,
            publicKeyURL: publicKeyURL,
            rootURL: sourceRoot,
            fileFilter: { url in url.pathExtension == "txt" },
            onProgress: { _ in }
        )

        #expect(result.imported.count == 1)
        #expect(result.imported.first?.lastPathComponent == "keep.txt")
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.lastPathComponent == "drop.log")
    }

    @Test func sameCreationDateProducesDistinctDestinations() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceRoot = testDir.appendingPathComponent("source")
        let a = sourceRoot.appendingPathComponent("a.txt")
        let b = sourceRoot.appendingPathComponent("b.txt")
        try TestFileHelper.createTestFile(at: a, content: "a")
        try TestFileHelper.createTestFile(at: b, content: "b")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try await service.importFiles(
            [sourceRoot],
            to: destination,
            publicKeyURL: publicKeyURL,
            rootURL: sourceRoot,
            dateExtractor: { _ in fixedDate },
            onProgress: { _ in }
        )

        #expect(result.imported.count == 2)
        #expect(result.failed.isEmpty)
        let encrypted = findEncryptedFiles(under: destination)
        #expect(encrypted.count == 2)
        #expect(Set(encrypted.map(\.path)).count == 2)
    }

    @Test func fileProcessorReportsProcessedAndHashesOriginal() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("doc.md")
        let originalContent = Data("# original\n".utf8)
        try TestFileHelper.createTestFile(at: sourceURL, data: originalContent)

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        let result = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            fileProcessor: { _ in Data("extracted".utf8) },
            onProgress: { _ in }
        )

        #expect(result.imported.count == 1)
        let info = result.importedInfo[0]
        #expect(info.wasProcessed == true)
        #expect(info.sourceContentHash == sha256Hex(originalContent))
    }

    @Test func fileProcessorThrowingForOneFilePutsItInFailed() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceRoot = testDir.appendingPathComponent("source")
        let good = sourceRoot.appendingPathComponent("good.txt")
        let bad = sourceRoot.appendingPathComponent("bad.txt")
        try TestFileHelper.createTestFile(at: good, content: "g")
        try TestFileHelper.createTestFile(at: bad, content: "b")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        struct ProcessorFailure: Error {}

        let result = try await service.importFiles(
            [sourceRoot],
            to: destination,
            publicKeyURL: publicKeyURL,
            rootURL: sourceRoot,
            fileProcessor: { url in
                if url.lastPathComponent == "bad.txt" { throw ProcessorFailure() }
                return Data("ok".utf8)
            },
            onProgress: { _ in }
        )

        #expect(result.imported.count == 1)
        #expect(result.imported.first?.lastPathComponent == "good.txt")
        #expect(result.failed.count == 1)
        #expect(result.failed.first?.url.lastPathComponent == "bad.txt")
    }

    @Test func discardDecisionLeavesNoFilesAtDestination() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("a.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        let result = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { _ in .discard },
            onProgress: { _ in }
        )

        #expect(result.imported.isEmpty)
        #expect(result.discarded.count == 1)
        #expect(findEncryptedFiles(under: destination).isEmpty)
        let stagePath = destination.appendingPathComponent(".importStage").path
        #expect(!FileManager.default.fileExists(atPath: stagePath))
    }

    @Test func retryFailedReencryptsOnlyFailures() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceRoot = testDir.appendingPathComponent("source")
        let good = sourceRoot.appendingPathComponent("good.txt")
        let bad = sourceRoot.appendingPathComponent("bad.txt")
        try TestFileHelper.createTestFile(at: good, content: "g")
        try TestFileHelper.createTestFile(at: bad, content: "b")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        // Processor that throws for bad.txt the first time, succeeds the second.
        struct ProcessorFailure: Error {}
        let attemptCounter = AttemptCounter()
        let result = try await service.importFiles(
            [sourceRoot],
            to: destination,
            publicKeyURL: publicKeyURL,
            rootURL: sourceRoot,
            fileProcessor: { url in
                if url.lastPathComponent == "bad.txt" && attemptCounter.recordAndCheckFirst() {
                    throw ProcessorFailure()
                }
                return Data("ok".utf8)
            },
            confirmAction: { summary in
                if summary.failed.isEmpty {
                    return .importStaged
                }
                return .retryFailed
            },
            onProgress: { _ in }
        )

        #expect(result.imported.count == 2)
        #expect(result.failed.isEmpty)
    }

    @Test func preflightGateResumesExistingImport() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceA = testDir.appendingPathComponent("a.txt")
        let sourceB = testDir.appendingPathComponent("b.txt")
        try TestFileHelper.createTestFile(at: sourceA, content: "a")
        try TestFileHelper.createTestFile(at: sourceB, content: "b")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        // First import: discard at modal → staging cleaned up
        let r1 = try await service.importFiles(
            [sourceA],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { _ in .discard },
            onProgress: { _ in }
        )
        #expect(r1.discarded.count == 1)

        // Second import: simulate an interrupted prior by manually leaving a manifest
        let (importID, importDir) = ImportManifestStore.newImportDir(under: destination)
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        let manifest = ImportManifest(
            importID: importID,
            destinationURL: destination,
            entries: []
        )
        try ImportManifestStore.write(manifest, in: importDir)

        // New import call with sourceB — should detect existing manifest and resume IT, ignoring sourceB
        let confirmCalled = ConfirmCallTracker()
        let r2 = try await service.importFiles(
            [sourceB],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { _ in
                confirmCalled.record()
                return .discard
            },
            onProgress: { _ in }
        )
        // sourceB was NOT imported — gate took over
        #expect(r2.imported.isEmpty)
        #expect(confirmCalled.count == 1)
        let stagePath = destination.appendingPathComponent(".importStage").path
        #expect(!FileManager.default.fileExists(atPath: stagePath))
    }

    @Test func metadataWriterIsCalledWithImportedInfo() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("a.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        let receivedInfos = ReceivedInfos()
        _ = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            metadataWriter: { infos in
                receivedInfos.set(infos)
            },
            onProgress: { _ in }
        )

        #expect(receivedInfos.snapshot.count == 1)
        #expect(receivedInfos.snapshot.first?.sourceURL == sourceURL)
    }

    @Test func metadataWriterFailureStillCleansUpStaging() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("a.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        struct WriterFail: LocalizedError {
            var errorDescription: String? { "writer boom" }
        }
        let result = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            metadataWriter: { _ in throw WriterFail() },
            onProgress: { _ in }
        )

        #expect(result.imported.count == 1)
        #expect(result.metadataError == "writer boom")
        let encrypted = findEncryptedFiles(under: destination)
        #expect(encrypted.count == 1)
        let stagePath = destination.appendingPathComponent(".importStage").path
        #expect(!FileManager.default.fileExists(atPath: stagePath))
    }

    @Test func progressEventsCoverEncryptingPhaseAndFinalize() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceRoot = testDir.appendingPathComponent("source")
        for i in 0..<3 {
            try TestFileHelper.createTestFile(
                at: sourceRoot.appendingPathComponent("f\(i).txt"),
                content: "x"
            )
        }

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()
        let collector = ProgressCollector()

        let result = try await service.importFiles(
            [sourceRoot],
            to: destination,
            publicKeyURL: publicKeyURL,
            rootURL: sourceRoot,
            onProgress: { collector.record($0) }
        )

        #expect(result.imported.count == 3)
        let events = collector.snapshot
        #expect(events.isEmpty == false)
        #expect(events.last?.processedFiles == 3)
        #expect(events.last?.totalFiles == 3)

        let encryptingEvents = events.filter { $0.phase == .encrypting }
        #expect(encryptingEvents.count >= 3)
    }

    @Test func deferredDecisionPreservesStagingForNextSession() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("a.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        let result = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { _ in .deferred },
            onProgress: { _ in }
        )

        #expect(result.imported.isEmpty)
        #expect(result.deferred.count == 1)
        #expect(result.discarded.isEmpty)
        // No files moved to the destination tree (everything still under .importStage).
        let movedToDest = findEncryptedFiles(under: destination)
            .filter { !$0.path.contains("/.importStage/") }
        #expect(movedToDest.isEmpty)
        // Manifest still present — pending import detected.
        #expect(DirectoryImportService.hasPendingImport(at: destination))
    }

    @Test func hasPendingImportReflectsLifecycle() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("a.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        #expect(!DirectoryImportService.hasPendingImport(at: destination))

        // Defer leaves it pending.
        _ = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { _ in .deferred },
            onProgress: { _ in }
        )
        #expect(DirectoryImportService.hasPendingImport(at: destination))

        // Resume + discard clears it.
        _ = try await service.importFiles(
            [],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { _ in .discard },
            onProgress: { _ in }
        )
        #expect(!DirectoryImportService.hasPendingImport(at: destination))
    }

    @Test func isResumedFlagDistinguishesFreshFromResumed() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("a.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        // First call: fresh.
        let freshFlag = SeenFlag()
        _ = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { summary in
                freshFlag.set(summary.isResumed)
                return .deferred
            },
            onProgress: { _ in }
        )
        #expect(freshFlag.value == false)

        // Second call (urls ignored — gate resumes): resumed.
        let resumedFlag = SeenFlag()
        _ = try await service.importFiles(
            [],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { summary in
                resumedFlag.set(summary.isResumed)
                return .discard
            },
            onProgress: { _ in }
        )
        #expect(resumedFlag.value == true)
    }

    private final class SeenFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Bool?
        func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
        var value: Bool? { lock.lock(); defer { lock.unlock() }; return _value }
    }

    @Test func committingResumeMovesRemainingAndIncludesAlreadyMoved() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let destination = testDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Build a synthetic .committing import: two entries, one already moved
        // to destination, one still staged.
        let (importID, importDir) = ImportManifestStore.newImportDir(under: destination)
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)

        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = Date(timeIntervalSince1970: 1_700_000_001)

        let dest1 = destination
            .appendingPathComponent(date1.filePathString)
            .appendingPathExtension("txt")
            .appendingPathExtension("bvf")
        let dest2 = destination
            .appendingPathComponent(date2.filePathString)
            .appendingPathExtension("txt")
            .appendingPathExtension("bvf")

        // Pre-move file 1 to destination (simulating "already moved before crash").
        try FileManager.default.createDirectory(at: dest1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("encrypted1".utf8).write(to: dest1)

        // Stage file 2 (simulating "not yet moved").
        let staged2Name = "entry2.bvf"
        let staged2 = importDir.appendingPathComponent(staged2Name)
        try Data("encrypted2".utf8).write(to: staged2)

        let staged1Name = "entry1.bvf"  // staged file gone; only destination exists
        let entry1 = ImportManifest.Entry(
            sourceURL: testDir.appendingPathComponent("a.txt"),
            date: date1, suffix: "txt", relativePath: "a.txt",
            stagedName: staged1Name, destinationPath: dest1
        )
        let entry2 = ImportManifest.Entry(
            sourceURL: testDir.appendingPathComponent("b.txt"),
            date: date2, suffix: "txt", relativePath: "b.txt",
            stagedName: staged2Name, destinationPath: dest2
        )
        var manifest = ImportManifest(
            importID: importID, destinationURL: destination,
            entries: [entry1, entry2]
        )
        manifest.status = .committing
        try ImportManifestStore.write(manifest, in: importDir)

        // Resume: with no NSOpenPanel involvement, just call importFiles.
        let service = DirectoryImportService()
        let publicKeyURL = try makePublicKey(in: testDir)
        let receivedInfos = ReceivedInfos()
        let result = try await service.importFiles(
            [],
            to: destination,
            publicKeyURL: publicKeyURL,
            metadataWriter: { infos in receivedInfos.set(infos) },
            onProgress: { _ in }
        )

        #expect(FileManager.default.fileExists(atPath: dest1.path))
        #expect(FileManager.default.fileExists(atPath: dest2.path))
        #expect(result.imported.count == 2)
        #expect(receivedInfos.snapshot.count == 2)
        #expect(!DirectoryImportService.hasPendingImport(at: destination))
    }

    @Test func awaitingConfirmManifestIsWipedOnNextScan() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let destination = testDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Write an .awaitingConfirm manifest (simulating a quit before confirmation).
        let (importID, importDir) = ImportManifestStore.newImportDir(under: destination)
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        let manifest = ImportManifest(
            importID: importID, destinationURL: destination,
            entries: [ImportManifest.Entry(
                sourceURL: testDir.appendingPathComponent("x.txt"),
                date: Date(), suffix: "txt", relativePath: "x.txt",
                stagedName: "x.bvf", destinationPath: nil
            )]
        )
        try ImportManifestStore.write(manifest, in: importDir)

        #expect(!DirectoryImportService.hasPendingImport(at: destination))
        #expect(!FileManager.default.fileExists(atPath: importDir.path))
    }

    @Test func deferredStatusPersistedOnDisk() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try makePublicKey(in: testDir)
        let sourceURL = testDir.appendingPathComponent("a.txt")
        try TestFileHelper.createTestFile(at: sourceURL, content: "x")

        let destination = testDir.appendingPathComponent("dest")
        let service = DirectoryImportService()

        _ = try await service.importFiles(
            [sourceURL],
            to: destination,
            publicKeyURL: publicKeyURL,
            confirmAction: { _ in .deferred },
            onProgress: { _ in }
        )

        let stageRoot = destination.appendingPathComponent(".importStage")
        let contents = try FileManager.default.contentsOfDirectory(at: stageRoot, includingPropertiesForKeys: nil)
        guard let importDir = contents.first else {
            Issue.record("No import dir on disk")
            return
        }
        let loaded = try ImportManifestStore.load(from: importDir)
        #expect(loaded.status == .deferred)
    }

    @Test func multipleDeferredKeepsNewestWipesRest() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let destination = testDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Two .deferred manifests with different createdAt. Newest survives.
        let (id1, dir1) = ImportManifestStore.newImportDir(under: destination)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        var m1 = ImportManifest(importID: id1, destinationURL: destination, entries: [])
        m1.status = .deferred
        try ImportManifestStore.write(m1, in: dir1)

        // Sleep briefly so createdAt timestamps differ.
        try await Task.sleep(nanoseconds: 50_000_000)

        let (id2, dir2) = ImportManifestStore.newImportDir(under: destination)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        var m2 = ImportManifest(importID: id2, destinationURL: destination, entries: [])
        m2.status = .deferred
        try ImportManifestStore.write(m2, in: dir2)

        let found = ImportManifestStore.findExistingImport(under: destination)
        #expect(found?.lastPathComponent == dir2.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: dir1.path))
    }
}
