import Foundation

/// Read a key file with surrounding whitespace trimmed.
public func readKeyFile(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
