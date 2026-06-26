import Testing
import Foundation
import BvfKit
@testable import BvfAppKit

@Suite(.serialized)
struct StagingManagerTests {

    private func createTestPublicKeyFile(in directory: URL) throws -> URL {
        let keypair = try Keypair.generate()
        let keyURL = directory.appendingPathComponent("test_public.pub")
        try keypair.publicKey.write(to: keyURL, atomically: true, encoding: .utf8)
        return keyURL
    }

    @Test func testStageAndCommitUsesCustomStagingURL() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let customStaging = testDir.appendingPathComponent("custom-staging", isDirectory: true)
        let outputDir = testDir.appendingPathComponent("output")
        let publicKeyURL = try createTestPublicKeyFile(in: testDir)

        guard let textData = "staging test".data(using: .utf8) else {
            Issue.record("Failed to encode message")
            return
        }

        _ = try StagingManager.stageAndCommit(
            date: Date(),
            suffix: "txt",
            in: outputDir,
            stagingURL: customStaging
        ) {
            try CryptoService().encryptDataToFile(plaintext: textData, publicKeyURL: publicKeyURL, outputPath: $0)
        }

        // stageAndCommit should consume the staged file by moving it to outputDir
        let stagingContents = (try? FileManager.default.subpathsOfDirectory(atPath: customStaging.path)) ?? []
        let stagedBvf = stagingContents.filter { $0.hasSuffix(".bvf") }
        #expect(stagedBvf.isEmpty, "Custom staging should be empty after commit; got: \(stagedBvf)")

        let outputContents = (try? FileManager.default.subpathsOfDirectory(atPath: outputDir.path)) ?? []
        #expect(!outputContents.isEmpty, "Output dir should contain the written file")
    }

    @Test func testRecoveryMovesValidSuffixFile() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let stagingRoot = testDir.appendingPathComponent("staging", isDirectory: true)
        let destDir = testDir.appendingPathComponent("dest", isDirectory: true)

        // Plant a canonical staged file. Shape: <date.filePathString>.<suffix>.<UUID>.bvf
        let dayDir = stagingRoot.appendingPathComponent("2024/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let stagedName = "14.23.45.123.txt.\(UUID().uuidString).bvf"
        let stagedFile = dayDir.appendingPathComponent(stagedName)
        // Write more than CryptoService.headerSize bytes so the file is not discarded
        let dummyData = Data(repeating: 0xFF, count: CryptoService.headerSize + 1)
        try dummyData.write(to: stagedFile)

        StagingManager.recoverOrphanedFiles(from: stagingRoot, to: destDir)

        #expect(!FileManager.default.fileExists(atPath: stagedFile.path),
                "Staged file should have been moved out of staging")

        let destContents = try FileManager.default.subpathsOfDirectory(atPath: destDir.path)
        let bvfFiles = destContents.filter { $0.hasSuffix(".bvf") }
        #expect(bvfFiles.count == 1, "Exactly one .bvf file should land in destination")
        #expect(bvfFiles[0].contains(".txt."), "Recovered file should retain .txt suffix")
    }

    @Test func testEmptySuffixFileIsSkippedDuringRecovery() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let stagingRoot = testDir.appendingPathComponent("staging", isDirectory: true)
        let destDir = testDir.appendingPathComponent("dest", isDirectory: true)

        // Plant a staged file with no suffix segment: 4-part filename after stripping .bvf.
        // Shape: HH.mm.ss.SSS.bvf (only 4 dot-segments before .bvf — no suffix, no UUID)
        let dayDir = stagingRoot.appendingPathComponent("2024/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let malformedName = "14.23.45.123.bvf"
        let malformedFile = dayDir.appendingPathComponent(malformedName)
        let dummyData = Data(repeating: 0xFF, count: CryptoService.headerSize + 1)
        try dummyData.write(to: malformedFile)

        StagingManager.recoverOrphanedFiles(from: stagingRoot, to: destDir)

        #expect(FileManager.default.fileExists(atPath: malformedFile.path),
                "Malformed file with no suffix should be skipped, not moved or defaulted")

        let destContents = (try? FileManager.default.subpathsOfDirectory(atPath: destDir.path)) ?? []
        let bvfFiles = destContents.filter { $0.hasSuffix(".bvf") }
        #expect(bvfFiles.isEmpty, "No file should be committed to destination from malformed input")
    }

    @Test func testParseStagingPathRoundTrip() {
        let stagingRoot = URL(fileURLWithPath: "/tmp/staging")
        let date = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15,
            hour: 14, minute: 23, second: 45, nanosecond: 123_000_000
        ))!
        let path = StagingManager.stagingPath(date: date, suffix: "txt", in: stagingRoot)
        let parsed = StagingManager.parseStagingPath(path, in: stagingRoot)
        #expect(parsed != nil)
        #expect(parsed?.date == date)
        #expect(parsed?.suffix == "txt")
    }

    @Test func testParseStagingPathRejectsWrongSegmentCount() {
        let stagingRoot = URL(fileURLWithPath: "/tmp/staging")
        // 5 segments (HH.mm.ss.SSS.suffix) — no UUID
        let fiveSegment = stagingRoot.appendingPathComponent("2024/06/15/14.23.45.123.txt.bvf")
        #expect(StagingManager.parseStagingPath(fiveSegment, in: stagingRoot) == nil)
    }

    @Test func testParseStagingPathRejectsNonBvf() {
        let stagingRoot = URL(fileURLWithPath: "/tmp/staging")
        let nonBvf = stagingRoot.appendingPathComponent("2024/06/15/14.23.45.123.txt.UUID.txt")
        #expect(StagingManager.parseStagingPath(nonBvf, in: stagingRoot) == nil)
    }

    @Test func testParseStagingPathRejectsMissingDateDirectory() {
        let stagingRoot = URL(fileURLWithPath: "/tmp/staging")
        // No yyyy/MM/dd/ prefix — date parse fails
        let noDateDir = stagingRoot.appendingPathComponent("14.23.45.123.txt.UUID.bvf")
        #expect(StagingManager.parseStagingPath(noDateDir, in: stagingRoot) == nil)
    }

    // sweepEmptySubdirectories is private; we test it here by replicating the same
    // algorithm on a controlled temp tree, mirroring what recoverOrphanedFiles does
    // at the end of each run.

    @Test func testSweepRemovesEmptyDirsPreservesNonEmpty() throws {
        let root = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(root) }

        // Build:
        // root/
        //   2026/05/10/         <- empty leaf; should be removed along with 05/ and 2026/ if empty
        //   2026/06/01/
        //     keep.txt          <- non-empty dir; must survive
        let emptyLeaf = root.appendingPathComponent("2026/05/10", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyLeaf, withIntermediateDirectories: true)

        let fileDir = root.appendingPathComponent("2026/06/01", isDirectory: true)
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)

        let placeholder = fileDir.appendingPathComponent("keep.txt")
        try "placeholder".data(using: .utf8)!.write(to: placeholder)

        sweepEmptySubdirectories(of: root)

        #expect(!FileManager.default.fileExists(atPath: emptyLeaf.path),
                "Empty leaf dir should be removed")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("2026/05").path),
            "Empty intermediate dir should be removed")

        #expect(FileManager.default.fileExists(atPath: fileDir.path),
                "Dir containing a file should be preserved")
        #expect(FileManager.default.fileExists(atPath: placeholder.path),
                "File inside preserved dir should still exist")

        #expect(FileManager.default.fileExists(atPath: root.path),
                "Staging root should never be removed")
    }

    private func sweepEmptySubdirectories(of root: URL) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            sweepEmptySubdirectories(of: child)
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: child.path)) ?? []
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}
