import Testing
import Foundation
@testable import BvfAppKitDecrypt

struct FileSearchServiceTests {

    // Construct a UTC-anchored Date so tests are stable across timezones and DST.
    private func utcDate(_ y: Int, _ M: Int, _ d: Int, _ h: Int = 0, _ m: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = M; c.day = d
        c.hour = h; c.minute = m; c.second = s
        return Calendar.utc.date(from: c)!
    }

    // FileManager.temporaryDirectory returns /var/..., but enumerator URLs are /private/var/...
    // Resolve the symlink up front so URL equality holds.
    private func makeRoot() -> URL {
        let dir = TestFileHelper.createTestDirectory()
        let cPath = dir.path.withCString { realpath($0, nil)! }
        defer { free(cPath) }
        return URL(fileURLWithPath: String(cString: cPath))
    }

    @Test func nonexistentRootReturnsEmpty() async {
        let url = URL(fileURLWithPath: "/var/empty/__definitely_missing__")
        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))

        let result = await FileSearchService.findMatchingFiles(in: url, dateRange: range)

        #expect(result.matchingFiles.isEmpty)
        #expect(result.totalScanned == 0)
        #expect(result.bvFound == 0)
        #expect(result.dateFailures == 0)
    }

    @Test func emptyRootReturnsEmpty() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles.isEmpty)
        #expect(result.totalScanned == 0)
    }

    @Test func findsBvfWithinRange() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let target = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 15, 12))

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles == [target])
        #expect(result.bvFound == 1)
        #expect(result.totalScanned == 1)
        #expect(result.dateFailures == 0)
    }

    @Test func excludesFilesOutsideRange() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let center = utcDate(2024, 10, 15, 12)
        let before = try TestFileHelper.createDateBasedFile(in: root, date: center.addingTimeInterval(-7200))
        let inRange = try TestFileHelper.createDateBasedFile(in: root, date: center)
        let after = try TestFileHelper.createDateBasedFile(in: root, date: center.addingTimeInterval(7200))

        let range = DateRange(start: center.addingTimeInterval(-1800), end: center.addingTimeInterval(1800))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles == [inRange])
        #expect(!result.matchingFiles.contains(before))
        #expect(!result.matchingFiles.contains(after))
        #expect(result.bvFound == 3)
        #expect(result.totalScanned == 3)
        #expect(result.dateFailures == 0)
    }

    @Test func searchSpansMultipleDays() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let a = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 15, 12))
        let b = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 16, 12))
        let c = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 17, 12))

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 18))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(Set(result.matchingFiles) == Set([a, b, c]))
    }

    @Test func searchCrossesMonthBoundary() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let last = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 31, 23, 30))
        let first = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 11, 1, 0, 30))

        let range = DateRange(start: utcDate(2024, 10, 31), end: utcDate(2024, 11, 2))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(Set(result.matchingFiles) == Set([last, first]))
    }

    @Test func searchCrossesYearBoundary() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let dec = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 12, 31, 23, 30))
        let jan = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2025, 1, 1, 0, 30))

        let range = DateRange(start: utcDate(2024, 12, 31), end: utcDate(2025, 1, 2))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(Set(result.matchingFiles) == Set([dec, jan]))
    }

    @Test func startBoundaryIsIncluded() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let boundary = utcDate(2024, 10, 15, 12)
        let atStart = try TestFileHelper.createDateBasedFile(in: root, date: boundary)

        let range = DateRange(start: boundary, end: boundary.addingTimeInterval(3600))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles == [atStart])
    }

    @Test func endBoundaryIsExcluded() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let boundary = utcDate(2024, 10, 15, 12)
        let atEnd = try TestFileHelper.createDateBasedFile(in: root, date: boundary)

        let range = DateRange(start: boundary.addingTimeInterval(-3600), end: boundary)
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(!result.matchingFiles.contains(atEnd))
        #expect(result.bvFound == 1)
    }

    @Test func ignoresNonBvfExtensions() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let date = utcDate(2024, 10, 15, 12)
        let bvf = try TestFileHelper.createDateBasedFile(in: root, date: date)

        let dayDir = bvf.deletingLastPathComponent()
        let txt = dayDir.appendingPathComponent("12.00.00.000.txt")
        try Data("not a bvf".utf8).write(to: txt)
        let other = dayDir.appendingPathComponent("12.00.00.000.dat")
        try Data("nope".utf8).write(to: other)

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles == [bvf])
        #expect(result.bvFound == 1)
        #expect(result.totalScanned == 3)
    }

    @Test func bvfWithInnerExtensionParsesCorrectly() async throws {
        // Filenames are written as HH.mm.ss.SSS.{innerExt}.bvf (e.g. .txt.bvf, .jpg.bvf).
        // The inner extension must not break date parsing.
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let dayDir = root.appendingPathComponent("2024/10/15")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let withInner = dayDir.appendingPathComponent("12.00.00.000.txt.bvf")
        try Data("x".utf8).write(to: withInner)

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles == [withInner])
        #expect(result.dateFailures == 0)
    }

    @Test func countsMalformedBvfAsDateFailure() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let dayDir = root.appendingPathComponent("2024/10/15")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let malformed = dayDir.appendingPathComponent("not-a-timestamp.bvf")
        try Data("junk".utf8).write(to: malformed)

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles.isEmpty)
        #expect(result.bvFound == 1)
        #expect(result.dateFailures == 1)
    }

    @Test func skipsDateDirectoriesOutsideRange() async throws {
        // The service should only enumerate yyyy/MM/dd directories that intersect the range.
        // A file in a totally unrelated date dir must not even be scanned.
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        _ = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2020, 1, 1, 12))
        let target = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 15, 12))

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles == [target])
        #expect(result.totalScanned == 1, "Should not visit the 2020 directory")
    }

    @Test func toleratesMissingDateDirectoriesInsideRange() async throws {
        // Range spans multiple days but only one day has any files.
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let only = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 16, 12))

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 18))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles == [only])
        #expect(result.totalScanned == 1)
    }

    @Test func ignoresRegularFileMasqueradingAsDateDirectory() async throws {
        // If somehow `<root>/2024/10/15` is a regular file rather than a directory,
        // the service must skip it without crashing.
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let monthDir = root.appendingPathComponent("2024/10")
        try FileManager.default.createDirectory(at: monthDir, withIntermediateDirectories: true)
        let fakeDayDir = monthDir.appendingPathComponent("15")
        try Data().write(to: fakeDayDir)

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles.isEmpty)
        #expect(result.totalScanned == 0)
    }

    @Test func zeroDurationRangeYieldsEmpty() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        _ = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 15, 12))

        let pt = utcDate(2024, 10, 15, 12)
        let range = DateRange(start: pt, end: pt)
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles.isEmpty)
    }

    @Test func invertedRangeYieldsEmpty() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        _ = try TestFileHelper.createDateBasedFile(in: root, date: utcDate(2024, 10, 15, 12))

        let range = DateRange(start: utcDate(2024, 10, 16), end: utcDate(2024, 10, 15))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        #expect(result.matchingFiles.isEmpty)
        #expect(result.totalScanned == 0)
    }

    /// The documented file layout is `yyyy/MM/dd/HH.mm.ss.SSS.{ext}.bvf` — flat under the day dir.
    /// The enumerator must not descend into stray subdirectories, otherwise positional path-parsing
    /// would mis-align and the file would be silently counted as a date-parse failure.
    @Test func nestedBvfBelowDayDirIsNotEnumerated() async throws {
        let root = makeRoot()
        defer { TestFileHelper.removeTestDirectory(root) }

        let nestedDir = root.appendingPathComponent("2024/10/15/sub")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nested = nestedDir.appendingPathComponent("12.00.00.000.bvf")
        try Data("x".utf8).write(to: nested)

        let range = DateRange(start: utcDate(2024, 10, 15), end: utcDate(2024, 10, 16))
        let result = await FileSearchService.findMatchingFiles(in: root, dateRange: range)

        // The `sub` directory entry itself is enumerated at the top level of the day dir,
        // but `.skipsSubdirectoryDescendants` prevents recursion into it, so the nested
        // .bvf is never seen — no bvFound, no dateFailures, no match.
        #expect(result.matchingFiles.isEmpty)
        #expect(result.bvFound == 0)
        #expect(result.dateFailures == 0)
    }
}
