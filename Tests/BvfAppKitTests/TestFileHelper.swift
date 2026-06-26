import Foundation
@testable import BvfAppKit

enum TestFileHelper {

    static func createTestDirectory() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        return testDir
    }

    static func removeTestDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func createTestFile(
        at url: URL,
        content: String,
        createDirectories: Bool = true
    ) throws {
        if createDirectories {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try content.data(using: .utf8)?.write(to: url)
    }

    static func createTestFile(
        at url: URL,
        data: Data,
        createDirectories: Bool = true
    ) throws {
        if createDirectories {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try data.write(to: url)
    }

    static func createTestKeyFile(
        at url: URL,
        salt: String = "dGVzdHNhbHQ=",
        nonce: String = "dGVzdG5vbmNl",
        ct: String = "dGVzdGN0"
    ) throws {
        let keyData: [String: String] = [
            "salt": salt,
            "nonce": nonce,
            "ct": ct
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: keyData)
        try createTestFile(at: url, data: jsonData)
    }

    static func createDateBasedFile(
        in baseDir: URL,
        date: Date,
        content: String = "test content"
    ) throws -> URL {
        let calendar = Calendar.utc
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )

        let yearDir = baseDir.appendingPathComponent(String(format: "%04d", components.year ?? 2024))
        let monthDir = yearDir.appendingPathComponent(String(format: "%02d", components.month ?? 1))
        let dayDir = monthDir.appendingPathComponent(String(format: "%02d", components.day ?? 1))

        let millisecond = (components.nanosecond ?? 0) / 1_000_000
        let fileName = String(
            format: "%02d.%02d.%02d.%03d.bvf",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            millisecond
        )

        let fileURL = dayDir.appendingPathComponent(fileName)
        try createTestFile(at: fileURL, content: content)
        return fileURL
    }

    static func createDateBasedFiles(
        in baseDir: URL,
        count: Int,
        startDate: Date = Date(),
        hourInterval: Int = 1
    ) throws -> [URL] {
        let calendar = Calendar.utc
        var files: [URL] = []

        for i in 0..<count {
            let date = calendar.date(
                byAdding: .hour,
                value: i * hourInterval,
                to: startDate
            ) ?? startDate

            let file = try createDateBasedFile(
                in: baseDir,
                date: date,
                content: "Test content \(i)"
            )
            files.append(file)
        }

        return files
    }

    static func cleanupFiles(_ files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func cleanupFilesAndDirectories(_ files: [URL], upTo baseDir: URL) {
        for file in files {
            try? FileManager.default.removeItem(at: file)

            var currentDir = file.deletingLastPathComponent()
            while currentDir.path.starts(with: baseDir.path) && currentDir != baseDir {
                let contents = try? FileManager.default.contentsOfDirectory(atPath: currentDir.path)
                if contents?.isEmpty ?? false {
                    try? FileManager.default.removeItem(at: currentDir)
                    currentDir = currentDir.deletingLastPathComponent()
                } else {
                    break
                }
            }
        }
    }

    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func readFileContent(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "TestFileHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode file content as UTF-8"
            ])
        }
        return content
    }

    static func readFileData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}
