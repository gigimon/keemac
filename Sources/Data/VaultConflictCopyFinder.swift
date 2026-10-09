import Domain
import Foundation

/// Finds copies sync services leave next to a database when two devices save it at the same time:
/// `Name 2.kdbx` (iCloud), `Name (… conflicted copy …).kdbx` (Dropbox), `Name.sync-conflict-….kdbx` (Syncthing).
public enum VaultConflictCopyFinder {
    public static func copies(of fileURL: URL) -> [VaultConflictCopy] {
        let directory = fileURL.deletingLastPathComponent()
        let baseName = NSRegularExpression.escapedPattern(for: fileURL.deletingPathExtension().lastPathComponent)
        let fileExtension = NSRegularExpression.escapedPattern(for: fileURL.pathExtension)
        let patterns: [(VaultConflictCopy.Provider, String)] = [
            (.iCloud, "^\(baseName) \\d+\\.\(fileExtension)$"),
            (.dropbox, "^\(baseName) \\(.*conflicted copy.*\\)\\.\(fileExtension)$"),
            (.syncthing, "^\(baseName)\\.sync-conflict-.+\\.\(fileExtension)$")
        ]
        let expressions = patterns.compactMap { provider, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (provider, $0) }
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var result: [VaultConflictCopy] = []
        for name in names where name != fileURL.lastPathComponent {
            let range = NSRange(name.startIndex..., in: name)
            guard let provider = expressions.first(where: { $0.1.firstMatch(in: name, range: range) != nil })?.0 else {
                continue
            }
            let url = directory.appendingPathComponent(name)
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            result.append(VaultConflictCopy(fileURL: url, provider: provider, modifiedAt: modifiedAt))
        }
        return result.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }
}
