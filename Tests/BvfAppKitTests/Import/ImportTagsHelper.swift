import Foundation
@testable import BvfAppKitDecrypt

/// Test-side indirection over the import auto-tag policy.
/// If the policy moves out of `ImportedFileInfo` in production code, update
/// this helper's body to call the new entry point. Tests should not change.
enum ImportTagsHelper {
    static func tagsFor(info: ImportedFileInfo) -> [String] {
        info.extractTags()
    }
}
