import Testing
import Foundation
import BvfKit
@testable import BvfAppKit

@MainActor
@Suite(.serialized)
struct BvfStoreTests {

    private func createTestPublicKeyFile(in directory: URL) throws -> URL {
        let keypair = try Keypair.generate()
        let keyURL = directory.appendingPathComponent("test_public.pub")
        try keypair.publicKey.write(to: keyURL, atomically: true, encoding: .utf8)
        return keyURL
    }

    @Test func testWriteEntrySuccess() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try createTestPublicKeyFile(in: testDir)
        let outputDir = testDir.appendingPathComponent("output")
        let message = "This is a test journal entry"
        guard let textData = message.data(using: .utf8) else {
            Issue.record("Failed to encode message")
            return
        }

        let fileURL = try await BvfStore.write(
            data: textData,
            to: outputDir,
            publicKeyURL: publicKeyURL,
            suffix: "txt"
        )

        #expect(TestFileHelper.fileExists(at: fileURL))
        #expect(fileURL.pathExtension == "bvf")

        let data = try TestFileHelper.readFileData(at: fileURL)
        #expect(data.count > 0)

        let versionHeader = "bvf-v1\n".data(using: .utf8)!
        #expect(data.starts(with: versionHeader), "File should start with version header")
    }

    @Test func testTwoWritesSameDateBothSucceedWithDistinctPaths() async throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let publicKeyURL = try createTestPublicKeyFile(in: testDir)
        let outputDir = testDir.appendingPathComponent("output")

        let fixedDate = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15, hour: 10, minute: 0, second: 0, nanosecond: 0
        ))!

        guard let data1 = "entry one".data(using: .utf8),
              let data2 = "entry two".data(using: .utf8) else {
            Issue.record("Failed to encode messages")
            return
        }

        let url1 = try await BvfStore.write(data: data1, to: outputDir, publicKeyURL: publicKeyURL, date: fixedDate, suffix: "txt")
        let url2 = try await BvfStore.write(data: data2, to: outputDir, publicKeyURL: publicKeyURL, date: fixedDate, suffix: "txt")

        #expect(url1 != url2, "Each write should produce a distinct file path")
        #expect(FileManager.default.fileExists(atPath: url1.path), "First file should exist")
        #expect(FileManager.default.fileExists(atPath: url2.path), "Second file should exist")
    }

    @Test func testMoveFileOnNoSuffixFileThrows() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let noSuffixFile = sourceDir.appendingPathComponent("14.23.45.123.bvf")
        try "fake content".data(using: .utf8)!.write(to: noSuffixFile)

        let destDir = testDir.appendingPathComponent("dest")
        let targetDate = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15, hour: 14, minute: 23, second: 45
        ))!

        #expect(throws: BvfStoreError.self) {
            try BvfStore.moveFile(from: noSuffixFile, to: targetDate, in: destDir)
        }
    }

    /// Helper: build the path that allocate would generate for a given date/suffix
    private func expectedPath(in folder: URL, date: Date, suffix: String) -> URL {
        folder
            .appendingPathComponent(date.filePathString)
            .appendingPathExtension(suffix)
            .appendingPathExtension("bvf")
    }

    @Test func testAllocateAvoidsExistingFiles() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let date = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15,
            hour: 10, minute: 30, second: 0, nanosecond: 0
        ))!

        let blockingPath = expectedPath(in: testDir, date: date, suffix: "txt")
        try TestFileHelper.createTestFile(at: blockingPath, content: "occupied")

        let (url, adjustedDate) = BvfStore.allocate(
            date: date, suffix: "txt", in: testDir
        )

        let expectedDate = date.addingTimeInterval(0.001)
        #expect(url == expectedPath(in: testDir, date: expectedDate, suffix: "txt"))
        #expect(adjustedDate == expectedDate)
    }

    @Test func testAllocateAvoidsReservedPaths() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let date = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15,
            hour: 10, minute: 30, second: 0, nanosecond: 0
        ))!

        let reservedPath = expectedPath(in: testDir, date: date, suffix: "txt").path
        let reserved: Set<String> = [reservedPath]

        let (url, adjustedDate) = BvfStore.allocate(
            date: date, suffix: "txt", in: testDir, reserved: reserved
        )

        let expectedDate = date.addingTimeInterval(0.001)
        #expect(url == expectedPath(in: testDir, date: expectedDate, suffix: "txt"))
        #expect(adjustedDate == expectedDate)
    }

    @Test func testAllocateAvoidsBothFileAndReserved() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let date = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15,
            hour: 10, minute: 30, second: 0, nanosecond: 0
        ))!

        let blockingPath = expectedPath(in: testDir, date: date, suffix: "txt")
        try TestFileHelper.createTestFile(at: blockingPath, content: "occupied")

        let plus1ms = date.addingTimeInterval(0.001)
        let reservedPath = expectedPath(in: testDir, date: plus1ms, suffix: "txt").path
        let reserved: Set<String> = [reservedPath]

        let (url, adjustedDate) = BvfStore.allocate(
            date: date, suffix: "txt", in: testDir, reserved: reserved
        )

        let expectedURL = expectedPath(in: testDir, date: date.addingTimeInterval(0.002), suffix: "txt")
        #expect(url == expectedURL)
        #expect(
            adjustedDate.filePathString
            == date.addingTimeInterval(0.002).filePathString
        )
    }

    @Test func testDeriveSuffixCanonicalURL() throws {
        let url = URL(fileURLWithPath: "/store/2024/06/15/14.23.45.123.txt.bvf")
        let suffix = try BvfStore.deriveSuffix(from: url)
        #expect(suffix == "txt")
    }

    @Test func testDeriveSuffixNoInnerSuffixThrows() {
        // Bug B regression: "14.23.45.123.bvf" has no inner suffix (4 dot-segments, not 5)
        let url = URL(fileURLWithPath: "/store/2024/06/15/14.23.45.123.bvf")
        #expect(throws: BvfStoreError.self) {
            try BvfStore.deriveSuffix(from: url)
        }
    }

    @Test func testDeriveSuffixMetadataFileThrows() {
        let url = URL(fileURLWithPath: "/store/metadata.bvf")
        #expect(throws: BvfStoreError.self) {
            try BvfStore.deriveSuffix(from: url)
        }
    }

    @Test func testAllocateEmptySuffixUsesDefault() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let date = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15,
            hour: 10, minute: 30, second: 0, nanosecond: 0
        ))!

        let (url, _) = BvfStore.allocate(date: date, suffix: "", in: testDir)
        #expect(url.lastPathComponent.hasSuffix(".\(BvfStore.defaultSuffix).bvf"))
    }

    @Test func testAllocateWithReservedBumpsMillisecond() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let date = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15,
            hour: 10, minute: 30, second: 0, nanosecond: 0
        ))!

        let (firstURL, _) = BvfStore.allocate(date: date, suffix: "txt", in: testDir)
        let reserved: Set<String> = [firstURL.path]

        let (secondURL, secondDate) = BvfStore.allocate(date: date, suffix: "txt", in: testDir, reserved: reserved)
        #expect(secondURL != firstURL)
        #expect(secondDate > date)
    }

    @Test func testCommitEndToEnd() throws {
        let testDir = TestFileHelper.createTestDirectory()
        defer { TestFileHelper.removeTestDirectory(testDir) }

        let stagingDir = testDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedFile = stagingDir.appendingPathComponent("staged.bvf")
        try "fake encrypted content".data(using: .utf8)!.write(to: stagedFile)

        let destDir = testDir.appendingPathComponent("dest")
        let date = Calendar.utc.date(from: DateComponents(
            year: 2024, month: 6, day: 15,
            hour: 10, minute: 30, second: 0, nanosecond: 0
        ))!

        let (resultURL, adjustedDate) = try BvfStore.commit(
            staged: stagedFile, date: date, suffix: "txt", in: destDir
        )

        #expect(!FileManager.default.fileExists(atPath: stagedFile.path))
        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        #expect(resultURL.lastPathComponent.hasSuffix(".txt.bvf"))
        #expect(adjustedDate.filePathString == date.filePathString)
    }
}
