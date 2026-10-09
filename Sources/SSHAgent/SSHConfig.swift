import Foundation

/// Adds and removes KeeMac's block in `~/.ssh/config` that points ssh at the agent socket.
public enum SSHConfigSetup {
    static let beginMarker = "# >>> KeeMac SSH agent (added by KeeMac)"
    static let endMarker = "# <<< KeeMac SSH agent"
    /// The lines shown in Settings and written to the file; ssh expands `~` itself.
    public static let lines = "Host *\n  IdentityAgent ~/.keemac/agent.sock"

    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    public static func isSetUp(_ text: String) -> Bool {
        text.contains(beginMarker) || text.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.lowercased().hasPrefix("identityagent") && line.contains(".keemac/agent.sock")
        }
    }

    /// The block goes first: ssh uses the first value it finds, and `Host *` keeps applying to every host.
    public static func adding(to text: String) -> String {
        guard !isSetUp(text) else { return text }
        let block = "\(beginMarker)\n\(lines)\n\(endMarker)\n"
        return text.isEmpty ? block : block + "\n" + text
    }

    public static func removing(from text: String) -> String {
        var result: [String] = []
        var isInBlock = false
        var skipsBlankAfterBlock = false
        for line in text.components(separatedBy: "\n") {
            if line == beginMarker {
                isInBlock = true
                continue
            }
            if isInBlock {
                if line == endMarker {
                    isInBlock = false
                    skipsBlankAfterBlock = true
                }
                continue
            }
            if skipsBlankAfterBlock, line.isEmpty {
                skipsBlankAfterBlock = false
                continue
            }
            skipsBlankAfterBlock = false
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    public static func isSetUp(at url: URL = defaultConfigURL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8)).map(isSetUp) ?? false
    }

    public static func setUp(at url: URL = defaultConfigURL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try write(adding(to: existing), to: url)
    }

    public static func remove(at url: URL = defaultConfigURL) throws {
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        try write(removing(from: existing), to: url)
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A private key found in `~/.ssh` for "Import Keys from ~/.ssh".
public struct SSHKeyFileCandidate: Sendable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let data: Data
    public let info: SSHKeyInfo
    /// Hosts whose `IdentityFile` in `~/.ssh/config` is this key.
    public let hosts: [String]
}

public enum SSHDirectoryScanner {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    public static func scan(directory: URL = defaultDirectory) -> [SSHKeyFileCandidate] {
        let config = (try? String(contentsOf: directory.appendingPathComponent("config"), encoding: .utf8)) ?? ""
        let hostsByFile = identityHosts(in: config, sshDirectory: directory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files
            .filter { $0.pathExtension != "pub" && !["config", "known_hosts", "authorized_keys"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), SSHKeyReader.looksLikePrivateKey(data),
                      let info = try? SSHKeyReader.inspect(data) else {
                    return nil
                }
                return SSHKeyFileCandidate(url: url, data: data, info: info, hosts: hostsByFile[url.standardizedFileURL.path] ?? [])
            }
    }

    /// Key file path → host names, from `Host` / `HostName` / `IdentityFile` lines. Wildcard-only patterns are skipped.
    public static func identityHosts(in config: String, sshDirectory: URL) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var patterns: [String] = []
        var hostName: String?
        var files: [String] = []
        func flush() {
            let hosts = (patterns.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") } + [hostName].compactMap { $0 })
            for file in files where !hosts.isEmpty {
                var list = result[file] ?? []
                for host in hosts where !list.contains(host) {
                    list.append(host)
                }
                result[file] = list
            }
            patterns = []
            hostName = nil
            files = []
        }
        let home = sshDirectory.deletingLastPathComponent().path
        for rawLine in config.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch parts[0].lowercased() {
            case "host":
                flush()
                patterns = value.split(separator: " ").map(String.init)
            case "match":
                flush()
            case "hostname":
                hostName = value
            case "identityfile":
                var path = value
                if path.hasPrefix("~/") {
                    path = home + "/" + path.dropFirst(2)
                } else if !path.hasPrefix("/") {
                    path = sshDirectory.appendingPathComponent(path).path
                }
                files.append(URL(fileURLWithPath: path).standardizedFileURL.path)
            default:
                break
            }
        }
        flush()
        return result
    }
}
